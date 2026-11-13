#!/usr/bin/env python3
"""mock_world.py: the MENES world the PocketIC mock suite loads into the mock MENES ledger
and the mock sale canister, and the holder table an independent computation expects from it.

The world has every case the snapshot must handle:
  - holders who held MENES directly, in their default account and in subaccounts;
  - stakes paid in by plain transfer and by approve + transfer_from;
  - a burn, approvals that cost a fee, and transfers between holders;
  - excluded principals (the unsold supply, the sale canister, a principal excluded for
    everything, and one excluded only for its stakes, whose held MENES still count);
  - a stake withdrawn before the close (inactive, its payout before the cut);
  - a stake made after the close, and transfers after the close, none of which count;
  - holders with a basket of nine, smaller baskets of one to eight neurons, holders below
    one minimum neuron (left out, their share spread over the rest), and one holder just
    over nine minimum neurons whose basket moves to rungs 1..8.

The expected table is computed here from the world itself (balances replayed in Python, the
table rule of table_oracle.py), not by the canister's code.

    python3 verification/mock_world.py <holders> <seed> [--json] > world.txt
"""
import hashlib, json, os, random, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from table_oracle import allocate, table_bytes, principal_text, MPV_STAKES, FEE, MIN  # noqa: E402

E8 = 10**8
NS = 10**9
CLOSE_S = 1_800_000_000
SALE = "d7ebz-3iaaa-aaaab-aerfq-cai"
MINTING = "ftmr2-maaaa-aaaab-aersa-cai"
UNSOLD = "vw2b5-vc43c-et5cx-guvr4-yt5y6-ttypw-3mef6-jmxcm-hvwby-5l3oq-yae"
LEDGER_FEE = 10_000


def exclusions():
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "Exclusions.mo")).read()
    out = {}
    for name in ("heldAndStaked", "heldOnly", "stakedOnly"):
        m = re.search(r"public let %s : \[Text\] = \[(.*?)\];" % name, src, re.S)
        out[name] = re.findall(r'"([a-z0-9-]+)"', m.group(1))
    return out


def replay(blocks, close_s, ex):
    """Balances per owner (subaccounts folded) after every block at or before the close.
    With `ex`, only the principals whose held MENES count, and only positive balances."""
    bal = {}

    def add(p, d):
        bal[p] = bal.get(p, 0) + d
    for b in blocks:
        if b["ts"] > close_s * NS:
            continue
        if b["kind"] == 0:
            add(b["to"], b["amount"])
        elif b["kind"] == 1:
            add(b["frm"], -(b["amount"] + b["fee"]))
            add(b["to"], b["amount"])
        elif b["kind"] == 2:
            add(b["frm"], -b["amount"])
        else:
            add(b["frm"], -b["fee"])
    assert all(v >= 0 for v in bal.values()), "a negative balance in the world"
    if ex is None:
        return bal
    skip = set(ex["heldAndStaked"]) | set(ex["heldOnly"])
    return {p: v for p, v in bal.items() if p not in skip and v > 0}


def world(count, seed):
    rng = random.Random(seed)
    ex = exclusions()
    excl_both = next(p for p in ex["heldAndStaked"] if p not in (SALE, MINTING, UNSOLD))
    staked_only = ex["stakedOnly"][0]
    holders = [principal_text(hashlib.sha224(b"mpv-mock-world|%d|%d" % (seed, i)).digest() + b"\x02") for i in range(count)]

    # Weights in e8s of MENES: mostly baskets of nine, then smaller baskets and holders below
    # one minimum neuron, and one just over nine minimum neurons.
    plan = {}
    for i, h in enumerate(holders):
        if i % 10 == 7:
            x = rng.randrange(10, 150) * E8                # a smaller basket
        elif i % 10 == 8:
            x = rng.randrange(2, 40) * E8 // 10            # below one minimum neuron
        elif i % 10 == 9 and i < 20:
            x = rng.randrange(1_000, 4_000)                # far below one minimum neuron
        else:
            x = int(10 ** rng.uniform(5, 6.5)) * E8        # basket
        staked = 0 if i % 3 == 0 else (x * rng.randrange(1, 100) // 100)
        plan[h] = (x - staked, staked)
    plan[holders[-1]] = (0, 0)          # funded last, once the other weights are known

    blocks, stakes = [], []
    ts = [(CLOSE_S - 30 * 86_400) * NS]

    def tick():
        ts[0] += rng.randrange(1, 4000) * NS
        return ts[0]

    def sub(rng_ok=True):
        return list(hashlib.sha256(b"sub|%d" % rng.randrange(10**9)).digest()) if rng_ok and rng.random() < 0.3 else None

    def mint(to, amount, to_sub=None):
        blocks.append(dict(kind=0, frm=MINTING, fromSub=None, to=to, toSub=to_sub, amount=amount, fee=0, ts=tick(), viaSpender=False))

    def transfer(frm, to, amount, frm_sub=None, to_sub=None, via=False, at=None):
        blocks.append(dict(kind=1, frm=frm, fromSub=frm_sub, to=to, toSub=to_sub, amount=amount, fee=LEDGER_FEE,
                           ts=at if at is not None else tick(), viaSpender=via))

    def approve(frm, spender, amount):
        blocks.append(dict(kind=3, frm=frm, fromSub=None, to=spender, toSub=None, amount=amount, fee=LEDGER_FEE, ts=tick(), viaSpender=False))

    def burn(frm, amount):
        blocks.append(dict(kind=2, frm=frm, fromSub=None, to=MINTING, toSub=None, amount=amount, fee=0, ts=tick(), viaSpender=False))

    mint(UNSOLD, 50_000_000 * E8)
    mint(SALE, 1_000_000 * E8)      # sale stock: the sale canister holds more than its stakes
    stake_id = [0]

    def stake(owner, amount, active=True, at=None):
        via = rng.random() < 0.5
        if via:
            approve(owner, SALE, amount + LEDGER_FEE)
        transfer(owner, SALE, amount, via=via, at=at)
        t = blocks[-1]["ts"]
        stakes.append(dict(id=stake_id[0], owner=owner, amount=amount, active=active, stakedAt=t, lockUntil=t + 120 * 86_400 * NS,
                           lockPeriod=rng.choice(["Months2", "Months4", "Months12", "Months18"]), pendingRewards=0, weightedAmount=amount))
        stake_id[0] += 1

    for h in holders[:-1]:
        held, staked = plan[h]
        fees = 3 * LEDGER_FEE                 # a subaccount move, an approve and a transfer
        s = sub()
        transfer(UNSOLD, h, held + staked + fees, to_sub=s)
        if s is not None:                     # move it to the default account, paying a fee
            transfer(h, h, held + staked + fees - LEDGER_FEE, frm_sub=s)
        if staked:
            stake(h, staked)
    # Transfers between holders, a burn.
    baskets = [h for i, h in enumerate(holders[:-1]) if i % 10 < 7]
    for _ in range(count):
        a, b = rng.sample(baskets, 2)
        amt = rng.randrange(1, 1000) * E8
        transfer(UNSOLD, a, amt + LEDGER_FEE)
        transfer(a, b, amt)
    transfer(UNSOLD, holders[0], 500 * E8)
    burn(holders[0], 200 * E8)
    # Excluded principals: everything of excl_both; only the stake of staked_only.
    transfer(UNSOLD, excl_both, 700_000 * E8)
    stake(excl_both, 300_000 * E8)
    transfer(UNSOLD, staked_only, 900_000 * E8 + 2 * LEDGER_FEE)
    stake(staked_only, 400_000 * E8)
    # A stake withdrawn before the close: inactive, paid back before the cut.
    w_owner = holders[1]
    transfer(UNSOLD, w_owner, 25_000 * E8 + 2 * LEDGER_FEE)
    stake(w_owner, 25_000 * E8)
    stakes[-1]["active"] = False
    transfer(SALE, w_owner, 25_000 * E8)

    # The holder just over nine minimum neurons: gross = 9 x (min + fee) + 1,000 e8s, so its
    # part of a genesis neuron holding less than a ninth of the pool falls below min + fee and
    # its basket moves to rungs 1..8.
    excl_held = set(ex["heldAndStaked"]) | set(ex["heldOnly"])
    excl_staked = set(ex["heldAndStaked"]) | set(ex["stakedOnly"])

    def weights_at_close(blocks_):
        bal_ = replay(blocks_, CLOSE_S, None)
        staked_ = {}
        for st in stakes:
            if st["stakedAt"] <= CLOSE_S * NS and st["active"]:
                staked_[st["owner"]] = staked_.get(st["owner"], 0) + st["amount"]
        rows_ = {}
        for p_, v in bal_.items():
            if p_ not in excl_held and v > 0:
                rows_[p_] = [v, 0]
        for p_, v in staked_.items():
            if p_ not in excl_staked:
                rows_.setdefault(p_, [0, 0])[1] = v
        return rows_

    # Fund the last holder so its gross among the holders kept is 9 x (min + fee) + 1,000,
    # found by running the rule itself (who is kept depends on the total), with the block at
    # the close (below) included.
    target_gross = 9 * (MIN + FEE) + 1_000
    pool = sum(MPV_STAKES)
    at_close = dict(kind=1, frm=UNSOLD, fromSub=None, to=holders[2], toSub=None, amount=3 * E8, fee=LEDGER_FEE,
                    ts=CLOSE_S * NS, viaSpender=False)
    w = 9 * E8
    for _ in range(40):
        fund = dict(kind=1, frm=UNSOLD, fromSub=None, to=holders[-1], toSub=None, amount=w, fee=LEDGER_FEE, ts=ts[0] + NS, viaSpender=False)
        rows_t = weights_at_close(blocks + [fund, at_close])
        own = sorted(rows_t)
        r = allocate([rows_t[o][0] + rows_t[o][1] for o in own], MPV_STAKES, FEE, MIN)
        me = own.index(holders[-1])
        j = r[0].index(me) if me in r[0] else None
        g = r[2][j] if j is not None else 0
        if j is not None and r[3][j] == 1 and len(r[4][j]) == 8 and g >= 9 * (MIN + FEE):
            break
        w_kept = sum(rows_t[own[i]][0] + rows_t[own[i]][1] for i in r[0]) - (w if j is not None else 0)
        w = -(-target_gross * w_kept // (pool - target_gross)) + (_ % 5) * 37
    transfer(UNSOLD, holders[-1], w)
    last_before = ts[0]
    assert last_before <= CLOSE_S * NS, "the world's pre-close blocks run past the close"
    # A block exactly at the close counts.
    transfer(UNSOLD, holders[2], 3 * E8, at=CLOSE_S * NS)
    ts[0] = CLOSE_S * NS
    # After the close: none of this counts.
    for _ in range(5):
        a, b = rng.sample(holders, 2)
        transfer(UNSOLD, a, 10 * E8 + LEDGER_FEE)
        transfer(a, b, 10 * E8)
    transfer(UNSOLD, holders[4], 1_000 * E8 + 2 * LEDGER_FEE)
    stake(holders[4], 1_000 * E8)
    # A payout from the sale canister after the cut, to an owner with only active stakes.
    active_owner = next(s["owner"] for s in stakes if s["active"] and s["owner"] in holders and s["owner"] != w_owner)
    transfer(SALE, active_owner, 7 * E8)

    # Replay to the close, independently of the canister.
    bal = replay(blocks, CLOSE_S, None)
    supply = 0
    for b in blocks:
        supply += b["amount"] if b["kind"] == 0 else (-b["amount"] if b["kind"] == 2 else -b["fee"])
    assert all(v >= 0 for v in replay(blocks, 2 * CLOSE_S, None).values()), "a negative balance after the close"

    rows = weights_at_close(blocks)
    owners = sorted(rows)
    weights = [rows[o][0] + rows[o][1] for o in owners]
    kept, dropped, gross, first, neurons, rounds, moved = allocate(weights, MPV_STAKES, FEE, MIN)
    table = [(owners[i], rows[owners[i]][0], rows[owners[i]][1], gross[j], first[j], neurons[j]) for j, i in enumerate(kept)]
    left = [(owners[i], rows[owners[i]][0], rows[owners[i]][1]) for i in dropped]
    h = hashlib.sha256(table_bytes(table, left, MPV_STAKES, FEE, MIN)).hexdigest()
    full = sum(1 for r in table if r[4] == 0)
    small = len(table) - full
    assert moved >= 1 and full >= 1 and small >= 2 and len(left) >= 2, "the world lacks a small basket, a dropped holder or a move"
    cut = sum(1 for b in blocks if b["ts"] <= CLOSE_S * NS)
    assert all(b["ts"] <= CLOSE_S * NS for b in blocks[:cut]), "blocks not in timestamp order around the close"
    withdraw_victim = next(s for s in stakes if s["active"] and s["owner"] in holders and s["stakedAt"] <= CLOSE_S * NS)
    return {
        "close_seconds": CLOSE_S,
        "genesis": MPV_STAKES, "fee": FEE, "min": MIN,
        "blocks": blocks, "stakes": stakes,
        "cut": cut, "supply": supply,
        "sale_balance_at_cut": bal.get(SALE, 0),
        "active_stake_total": sum(s["amount"] for s in stakes if s["active"] and s["stakedAt"] <= CLOSE_S * NS),
        "withdrawal_fault": {"stake_id": withdraw_victim["id"], "owner": withdraw_victim["owner"], "amount": withdraw_victim["amount"]},
        "excluded": {"both": excl_both, "staked_only": staked_only,
                     "staked_only_held": rows.get(staked_only, [0, 0])[0]},
        "expected": {
            "hash": h, "moved": moved, "rounds": rounds,
            "counts": {"nine": full, "smaller": small, "dropped": len(left), "neurons": sum(len(r[5]) for r in table)},
            "rows": [{"owner": o, "held": hd, "staked": st, "gross": g, "first": f, "neurons": n} for o, hd, st, g, f, n in table],
            "dropped": [{"owner": o, "held": hd, "staked": st} for o, hd, st in left],
        },
    }


def lines(w):
    """Plain lines for the Rust suite: M key value | B block | S stake | R expected row
    (owner held staked gross first-rung parts) | D expected dropped holder."""
    out = []
    for key in ("close_seconds", "fee", "min", "cut", "supply", "sale_balance_at_cut", "active_stake_total"):
        out.append("M %s %d" % (key, w[key]))
    out.append("M genesis %s" % ",".join(str(x) for x in w["genesis"]))
    out.append("M hash %s" % w["expected"]["hash"])
    out.append("M moved %d" % w["expected"]["moved"])
    out.append("M withdrawal %d %s %d" % (w["withdrawal_fault"]["stake_id"], w["withdrawal_fault"]["owner"], w["withdrawal_fault"]["amount"]))
    out.append("M excluded_both %s" % w["excluded"]["both"])
    out.append("M staked_only %s %d" % (w["excluded"]["staked_only"], w["excluded"]["staked_only_held"]))
    hx = lambda b: "-" if b is None else bytes(b).hex()
    for b in w["blocks"]:
        out.append("B %d %s %s %s %s %d %d %d %d" % (b["kind"], b["frm"], hx(b["fromSub"]), b["to"], hx(b["toSub"]),
                                                    b["amount"], b["fee"], b["ts"], 1 if b["viaSpender"] else 0))
    for s in w["stakes"]:
        out.append("S %d %s %d %d %d %d %s" % (s["id"], s["owner"], s["amount"], 1 if s["active"] else 0, s["stakedAt"], s["lockUntil"], s["lockPeriod"]))
    for r in w["expected"]["rows"]:
        out.append("R %s %d %d %d %d %s" % (r["owner"], r["held"], r["staked"], r["gross"], r["first"], ",".join(str(x) for x in r["neurons"])))
    for d in w["expected"]["dropped"]:
        out.append("D %s %d %d" % (d["owner"], d["held"], d["staked"]))
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    w = world(int(sys.argv[1]), int(sys.argv[2]))
    if len(sys.argv) > 3 and sys.argv[3] == "--json":
        json.dump(w, sys.stdout)
    else:
        sys.stdout.write(lines(w))
    sys.stderr.write("world: %d blocks (%d at or before the close), %d stakes; table %d rows %s, %d moved to rungs 1..8, %d rounds; hash %s\n" % (
        len(w["blocks"]), w["cut"], len(w["stakes"]), len(w["expected"]["rows"]), w["expected"]["counts"],
        w["expected"]["moved"], w["expected"]["rounds"], w["expected"]["hash"]))

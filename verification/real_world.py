#!/usr/bin/env python3
"""real_world.py: turns a MENES ledger walk, the sale canister's stake records and the table
the off-chain builder made from them into plain lines for the real-SNS PocketIC run.

Two worlds:

  replay     every block of the walk, replayed on the real ledger module with the original
             caller, accounts, amount, fee, created_at_time and timestamp; the stake records
             as read; the table the builder made at the same cut.

             python3 verification/real_world.py replay <raw_txs.json> <stakes dir> <table.json> <close s>

  synthetic  the ledger's initial balances are the table's holdings (the sale canister holds
             the sum of the stakes); one active stake record per staker, made before the close.

             python3 verification/real_world.py synthetic <table.json>

Lines: M key value | I owner amount (initial balance) | L kind from to spender amount fee
created_at_time ts (one per block) | S stake | R expected row | D expected dropped holder. No
data lives in this repository. The builder's dropped.json is read from beside table.json.
"""
import glob, json, os, sys

SALE = "d7ebz-3iaaa-aaaab-aerfq-cai"


def n(x):
    return int(str(x).replace("_", ""))


def opt(v):
    return v[0] if v else None


def expected_hash(table):
    """The table hash the builder printed into checks.txt beside table.json."""
    for line in open(os.path.join(os.path.dirname(table), "checks.txt")):
        if "table hash" in line:
            return line.split("table hash")[1].split()[0]
    raise SystemExit("no table hash in checks.txt beside %s" % table)


def dropped_of(table):
    return json.load(open(os.path.join(os.path.dirname(table), "dropped.json")))


def rows(table):
    """R owner held staked gross first-rung parts | D owner held staked (dropped)."""
    out = ["M hash %s" % expected_hash(table)]
    for r in json.load(open(table)):
        out.append("R %s %d %d %d %d %s" % (r["owner"], r["held"], r["staked"], r["gross"], r["first_rung"],
                                            ",".join(str(x) for x in r["neurons"])))
    for d in dropped_of(table):
        out.append("D %s %d %d" % (d["owner"], d["held"], d["staked"]))
    return out


def acct(a):
    if a["subaccount"]:
        raise SystemExit("a subaccount in the walk: this converter does not carry them")
    return a["owner"]


def replay(raw, stakes_dir, table, close_s):
    blocks = json.load(open(raw))
    out = ["M close %d" % close_s, "M blocks %d" % len(blocks)]
    for i, b in enumerate(blocks):
        ts = n(b["timestamp"])
        if b["kind"] == "mint":
            m = b["mint"][0]
            if i > 1:
                raise SystemExit("a mint after the initial balances at block %d" % i)
            out.append("I %s %d %d" % (acct(m["to"]), n(m["amount"]), ts))
            continue
        if b["kind"] == "transfer":
            t = b["transfer"][0]
            if t["memo"]:
                raise SystemExit("a memo at block %d" % i)
            sp = opt(t["spender"])
            out.append("L %s %s %s %s %d %s %s %d" % ("transfer_from" if sp else "transfer", acct(t["from"]), acct(t["to"]),
                                                      acct(sp) if sp else "-", n(t["amount"]),
                                                      str(n(opt(t["fee"]))) if opt(t["fee"]) is not None else "-",
                                                      str(n(opt(t["created_at_time"]))) if opt(t["created_at_time"]) is not None else "-", ts))
        elif b["kind"] == "approve":
            a = b["approve"][0]
            if a["memo"] or a["expires_at"] or a["expected_allowance"]:
                raise SystemExit("an approve with a memo, expiry or expected allowance at block %d" % i)
            out.append("L approve %s %s - %d %s %s %d" % (acct(a["from"]), acct(a["spender"]), n(a["amount"]),
                                                       str(n(opt(a["fee"]))) if opt(a["fee"]) is not None else "-",
                                                       str(n(opt(a["created_at_time"]))) if opt(a["created_at_time"]) is not None else "-", ts))
        else:
            raise SystemExit("block %d has kind %s" % (i, b["kind"]))
    stakes = []
    for f in glob.glob(os.path.join(stakes_dir, "*.json")):
        for s in json.load(open(f)):
            stakes.append(s)
    stakes.sort(key=lambda s: n(s["id"]))
    for s in stakes:
        out.append("S %d %s %d %d %d %d %s %d %d" % (n(s["id"]), s["owner"], n(s["amount"]), 1 if s["active"] else 0,
                                                    n(s["stakedAt"]), n(s["lockUntil"]), next(iter(s["lockPeriod"])),
                                                    n(s["pendingRewards"]), n(s["weightedAmount"])))
    return out + rows(table)


def synthetic(table):
    rs = json.load(open(table)) + dropped_of(table)
    out = ["M close 0", "M blocks 0"]
    staked = 0
    sid = 0
    for r in rs:
        if r["held"]:
            out.append("I %s %d 0" % (r["owner"], r["held"]))
        if r["staked"]:
            out.append("S %d %s %d 1 0 0 Months12 0 %d" % (sid, r["owner"], r["staked"], r["staked"]))
            sid += 1
            staked += r["staked"]
    out.append("I %s %d 0" % (SALE, staked))
    return out + rows(table)


if __name__ == "__main__":
    if sys.argv[1] == "replay":
        lines = replay(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]))
    else:
        lines = synthetic(sys.argv[2])
    sys.stdout.write("\n".join(lines) + "\n")
    sys.stderr.write("%d lines\n" % len(lines))

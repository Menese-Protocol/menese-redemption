#!/usr/bin/env python3
"""table_oracle.py: an independent Python statement of the holder table rule, and the
generator of the vectors the Motoko logic battery checks itself against.

The rule (src/Logic.mo `allocate`, and the off-chain table builder), U = minimum + fee:
  1. S_0 = every holder; gross over S_i = largest remainder of the pool (the sum of the
     genesis stakes) by weight over S_i, ties to the lower principal text (the lower index
     here); S_{i+1} = the holders of S_i with gross >= U; repeat until nothing changes.
     The holders left out are published as the dropped list.
  2. n = min(9, gross // U).
  3. n < 9: parts at rungs 1..n, gross // n each, the remainder on the last.
  4. n = 9: part at rung k = largest remainder of (stake_k - the smaller baskets' parts at
     k) over the baskets of nine by weight.
  5. a basket of nine with a part below U moves to rungs 1..8 (n = 8); repeat 4.

    python3 verification/table_oracle.py vectors > test/Vectors.mo
    python3 verification/table_oracle.py synthetic <count> <seed>   (prints the table hash)
"""
import base64, binascii, hashlib, random, sys

NEURONS = 9
MPV_STAKES = [166_666_600_000_000] * 8 + [166_667_200_000_000]
FEE, MIN = 10_000, 1_000_000_000


def lr(total, weights):
    W = sum(weights)
    if W == 0:
        return [0] * len(weights)
    base = [total * w // W for w in weights]
    rest = total - sum(base)
    order = sorted(range(len(weights)), key=lambda i: (-((total * weights[i]) % W), i))
    for i in order[:rest]:
        base[i] += 1
    return base


def small_parts(g, n):
    q = g // n
    return [q] * (n - 1) + [g - q * (n - 1)]


def allocate(weights, stakes, fee, mn):
    """-> (kept, dropped, gross, first_rung, neurons, drop_rounds, moved) or "err"."""
    U = mn + fee
    pool = sum(stakes)
    S = list(range(len(weights)))
    rounds = 0
    while True:
        if not S:
            return "err"
        gross = lr(pool, [weights[i] for i in S])
        rounds += 1
        nxt = [i for i, g in zip(S, gross) if g >= U]
        if len(nxt) == len(S):
            break
        S = nxt
    kept = S
    dropped = [i for i in range(len(weights)) if i not in set(kept)]
    count = [min(NEURONS, g // U) for g in gross]
    moved = 0
    for _ in range(len(kept) + 1):
        small = [0] * NEURONS
        for j, c in enumerate(count):
            if c < NEURONS:
                for r, x in enumerate(small_parts(gross[j], c)):
                    small[1 + r] += x
        full = [j for j, c in enumerate(count) if c == NEURONS]
        if not full or any(small[k] > stakes[k] for k in range(NEURONS)):
            return "err"
        perk = [lr(stakes[k] - small[k], [weights[kept[j]] for j in full]) for k in range(NEURONS)]
        short = [full[f] for f in range(len(full)) if min(perk[k][f] for k in range(NEURONS)) < U]
        if not short:
            neurons = [None] * len(kept)
            for f, j in enumerate(full):
                neurons[j] = [perk[k][f] for k in range(NEURONS)]
            for j, c in enumerate(count):
                if c < NEURONS:
                    neurons[j] = small_parts(gross[j], c)
            first = [0 if c == NEURONS else 1 for c in count]
            return kept, dropped, gross, first, neurons, rounds, moved
        for j in short:
            count[j] = NEURONS - 1
            moved += 1
    return "err"


def principal_text(raw):
    crc = binascii.crc32(raw).to_bytes(4, "big")
    s = base64.b32encode(crc + raw).decode().lower().rstrip("=")
    return "-".join(s[i:i + 5] for i in range(0, len(s), 5))


def principal_bytes(text):
    t = text.replace("-", "").upper()
    return base64.b32decode(t + "=" * (-len(t) % 8))[4:]


def table_bytes(rows, dropped, stakes, fee, mn):
    """rows: (owner, held, staked, gross, first_rung, parts); dropped: (owner, held, staked)."""
    u64 = lambda x: int(x).to_bytes(8, "big")
    def who(owner):
        pb = principal_bytes(owner)
        return bytes([len(pb)]) + pb
    out = bytearray(b"MPV-HOLDER-TABLE-v2") + u64(fee) + u64(mn) + bytes([NEURONS]) + b"".join(u64(s) for s in stakes)
    out += len(rows).to_bytes(4, "big")
    for owner, held, staked, g, first, parts in rows:
        out += who(owner) + u64(held) + u64(staked) + u64(g) + bytes([first, len(parts)]) + b"".join(u64(x) for x in parts)
    out += len(dropped).to_bytes(4, "big")
    for owner, held, staked in dropped:
        out += who(owner) + u64(held) + u64(staked)
    return bytes(out)


def synthetic(count, seed):
    """The same synthetic holders as the table builder's --synthetic mode."""
    rng = random.Random(seed)
    w = {}
    for i in range(count):
        raw = hashlib.sha224(b"mpv-synthetic|%d|%d" % (seed, i)).digest() + b"\x02"
        x = int(10 ** rng.uniform(1, 13))
        held = x if rng.random() < 0.6 else rng.randrange(x + 1)
        w[principal_text(raw)] = (held, x - held)
    owners = sorted(w)
    weights = [w[o][0] + w[o][1] for o in owners]
    kept, dropped, gross, first, neurons, _, _ = allocate(weights, MPV_STAKES, FEE, MIN)
    rows = [(owners[i], w[owners[i]][0], w[owners[i]][1], gross[j], first[j], neurons[j]) for j, i in enumerate(kept)]
    left = [(owners[i], w[owners[i]][0], w[owners[i]][1]) for i in dropped]
    return rows, left, hashlib.sha256(table_bytes(rows, left, MPV_STAKES, FEE, MIN)).hexdigest()


def mo_nat_list(xs):
    return "[" + ", ".join(str(x) for x in xs) + "]"


def vectors():
    rng = random.Random(20261113)
    cases = []
    # Two families. On the MPV fee and minimum with small genesis stakes: every outcome at
    # realistic sizes. On a unit of 10 (fee 1, minimum 9): the rounding edges, where one
    # largest-remainder unit decides whether a holder reaches one minimum neuron, so a
    # second round of the redistribution drops someone the first round kept.
    want = {"err": 4, "iter": 5, "moved": 6, "drop": 8, "small": 8, "plain": 6}
    tries = 0
    while sum(want.values()) > 0 and tries < 2000000:
        tries += 1
        if tries % 2:
            n, fee, mn = rng.randint(1, 14), FEE, MIN
            stakes = [rng.randint(20, 400) * 10**8 for _ in range(NEURONS)]
            weights = [int(10 ** rng.uniform(0, 6)) for _ in range(n)]
        else:
            n, fee, mn = rng.randint(10, 40), 1, 9
            stakes = [rng.randint(40, 200) for _ in range(NEURONS)]
            weights = [int(10 ** rng.uniform(0, 3)) for _ in range(n)]
        r = allocate(weights, stakes, fee, mn)
        if r == "err":
            kind = "err"
        else:
            kept, dropped, gross, first, neurons, rounds, moved = r
            kind = ("iter" if rounds >= 3 else "moved" if moved else "drop" if dropped
                    else "small" if any(first) else "plain")
        if want[kind] > 0:
            want[kind] -= 1
            cases.append((weights, stakes, fee, mn, r))
    rows, left, h = synthetic(300, 7)
    L = lambda xs: "[" + ", ".join(str(x) for x in xs) + "]"
    out = ["/// Vectors.mo: generated by verification/table_oracle.py (an independent Python",
           "/// statement of the table rule). Do not edit by hand.", "", "module {",
           "  public type Case = { weights : [Nat]; stakes : [Nat]; fee : Nat; min : Nat; ok : Bool;",
           "    kept : [Nat]; dropped : [Nat]; gross : [Nat]; firstRung : [Nat]; neurons : [[Nat]];",
           "    dropRounds : Nat; moved : Nat };",
           "  public let cases : [Case] = ["]
    for weights, stakes, fee, mn, r in cases:
        if r == "err":
            out.append("    { weights = %s; stakes = %s; fee = %d; min = %d; ok = false; kept = []; dropped = []; gross = []; firstRung = []; neurons = []; dropRounds = 0; moved = 0 }," % (L(weights), L(stakes), fee, mn))
        else:
            kept, dropped, gross, first, neurons, rounds, moved = r
            out.append("    { weights = %s; stakes = %s; fee = %d; min = %d; ok = true; kept = %s; dropped = %s; gross = %s; firstRung = %s; neurons = [%s]; dropRounds = %d; moved = %d }," % (
                L(weights), L(stakes), fee, mn, L(kept), L(dropped), L(gross), L(first), ", ".join(L(x) for x in neurons), rounds, moved))
    out.append("  ];")
    out.append("  /// A synthetic 300-holder world on the MPV genesis stakes (every holder, in")
    out.append("  /// principal-text order), and the canonical hash of its table.")
    allrows = sorted([(r[0], r[1], r[2]) for r in rows] + left)
    out.append("  public let synthOwners : [Text] = [%s];" % ", ".join('"%s"' % r[0] for r in allrows))
    out.append("  public let synthHeld : [Nat] = %s;" % L(r[1] for r in allrows))
    out.append("  public let synthStaked : [Nat] = %s;" % L(r[2] for r in allrows))
    out.append('  public let synthHash : Text = "%s";' % h)
    out.append("  public let synthKept : Nat = %d;" % len(rows))
    out.append("}")
    print("\n".join(out))
    sys.stderr.write("vectors: %d cases (%s); synthetic 300: %d kept, %d dropped, hash %s\n" % (
        len(cases), ", ".join("%s %d short" % (k, v) for k, v in want.items() if v), len(rows), len(left), h))


if __name__ == "__main__":
    if sys.argv[1] == "vectors":
        vectors()
    elif sys.argv[1] == "synthetic":
        rows, left, h = synthetic(int(sys.argv[2]), int(sys.argv[3]))
        print(h)

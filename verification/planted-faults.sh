#!/usr/bin/env bash
# planted-faults.sh: every safety property has a test that FAILS when it is removed.
#
# A passing test is evidence only if it would fail on the defect it is about. Each fault
# below is one small, named edit to the source that removes one property. For each:
#
#   1. copy the tree to a scratch directory (nothing in this tree is changed),
#   2. apply the edit, refusing if its text is not found exactly once,
#   3. rebuild the module and run the suite named for it: the logic battery, or groups of
#      the PocketIC mock suite (verification/pocketic/menese_redemption_mocks.rs),
#   4. record RED (the suite caught it) or GREEN (it did not).
#
# Every fault is expected RED. A GREEN row is reported, never hidden. The unpatched tree
# must be green on the same suites; that is the baseline row.
#
# Environment: MOCKS_BIN (the built menese_redemption_mocks test binary), MOCKS_WORLD (the
# output of verification/mock_world.py), POCKET_IC_BIN.
# Usage: verification/planted-faults.sh [scratch dir] [fault id ...]
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRATCH="${1:-${TMPDIR:-/tmp}/redemption-faults}"
shift || true
ONLY="$*"
mkdir -p "$SCRATCH"
: "${MOCKS_BIN:?set MOCKS_BIN to the menese_redemption_mocks test binary}"
: "${MOCKS_WORLD:?set MOCKS_WORLD to a mock_world.py output}"
: "${POCKET_IC_BIN:?set POCKET_IC_BIN}"

python3 - "$HERE" "$SCRATCH" "$ONLY" <<'PY'
import os, re, shutil, subprocess, sys

here, scratch, only = sys.argv[1], sys.argv[2], sys.argv[3].split()
R = "src/Redemption.mo"
L = "src/Logic.mo"
G = "src/SnsGov.mo"

# id, what the fault removes, [(file, old, new)], suite ("logic" or "mocks:<groups>").
FAULTS = [
  ("P01", "Split taken from the wrong genesis neuron for k",
   [(R, "manage(b, parentId(k), #Split(", "manage(b, parentId((k + 1) % L.NEURONS), #Split(")], "mocks:H"),
  ("P02", "a holder skipped from the table",
   [(R, "let rows = Array.sort<(Principal, (Nat, Nat))>(", "let rows0 = Array.sort<(Principal, (Nat, Nat))>("),
    (R, "    let weights = Array.map<(Principal, (Nat, Nat)), Nat>(rows,",
        "    let rows = Array.sliceToArray<(Principal, (Nat, Nat))>(rows0, 1, rows0.size());\n    let weights = Array.map<(Principal, (Nat, Nat)), Nat>(rows,")], "mocks:H"),
  ("P03", "an exclusion removed from the compiled-in list",
   [("src/Exclusions.mo", '    "24f6f-xjfaq-hmkqk-7zoql-w62gn-cvrmp-mzgpk-tu26t-i5njy-6puxq-5ae",\n', "")], "mocks:H"),
  ("P04", "the canister's own permissions never removed (self-removal skipped)",
   [(R, 'if (mine.size() == 0) { advanceAfterStrip(i); return #ok(tag # "already stripped") };',
        'if (true) { advanceAfterStrip(i); return #ok(tag # "already stripped") };')], "mocks:H"),
  ("P05", "liquid payments re-enabled: a basket of fewer than nine is paid by Disburse instead of neurons",
   [(G, "    #Split : Split;\n", "    #Split : Split;\n    #Disburse : { to_account : ?{ owner : ?Principal; subaccount : ?{ subaccount : Blob } }; amount : ?{ e8s : Nat64 } };\n"),
    (G, "    #Split : { created_neuron_id : ?NeuronId };\n", "    #Split : { created_neuron_id : ?NeuronId };\n    #Disburse : { transfer_block_height : Nat64 };\n"),
    (R, "        let seed = switch (memoSeed) { case (?s) s; case null return #err(tag # \"no memo seed yet\") };\n",
        "        if (e.neurons.size() < L.NEURONS) {\n"
        "          let dest = switch (progress[i].destination) { case (?d) d; case null return #ok(tag # \"awaiting a destination\") };\n"
        "          ignore await* manage(b, parentId(k), #Disburse({ to_account = ?{ owner = ?dest; subaccount = null }; amount = ?{ e8s = Nat64.fromNat(e.gross) } }));\n"
        "          takenFrom[k] += e.gross;\n"
        "          setStatus(i, #Done, null, null);\n"
        "          return #ok(tag # \"paid liquid\");\n"
        "        };\n"
        "        let seed = switch (memoSeed) { case (?s) s; case null return #err(tag # \"no memo seed yet\") };\n")], "mocks:H"),
  ("P06", "a genesis neuron handed over while other shares are still owed from it",
   [(R, "if (not othersOwedAt(k, i)) {", "if (true) {")], "mocks:H"),
  ("P07", "the cut excludes a block timestamped exactly at the close",
   [(L, "Nat64.toNat(timestampNs) <= Nat64.toNat(closeSeconds) * 1_000_000_000;", "Nat64.toNat(timestampNs) < Nat64.toNat(closeSeconds) * 1_000_000_000;")], "mocks:H"),
  ("P08", "the supply check removed",
   [(R, "if (supplyAll != s) return halt(", "if (false) return halt(")], "mocks:F"),
  ("P09", "the missing-block check removed",
   [(R, "if (run == 0) return halt(", "if (false) return halt(")], "mocks:F"),
  ("P10", "the withdrawal rule removed (post-cut payouts ignored)",
   [(R, "switch (L.unresolvedWithdrawal(inactive, List.toArray(saleAfterCut))) {", "switch (L.unresolvedWithdrawal(inactive, [])) {")], "mocks:F"),
  ("P11", "an aborted swap not recognised",
   [(R, "case (?4, _) {", "case (?99, _) {")], "mocks:F"),
  ("P12", "a stake's active flag ignored when the two reads are compared",
   [(L, "          or x.active != y.active or x.stakedAt != y.stakedAt) return false;", "          or x.stakedAt != y.stakedAt) return false;")], "mocks:F"),
  ("P13", "ingress processNext and setNeuronDestination accepted from anyone",
   [(R, "        not Principal.isAnonymous(caller) and Map.get(ownerIndex, Principal.compare, caller) != null;", "        true;")], "mocks:B"),
  ("P14", "bound to a root NNS SNS-W does not list",
   [(R, "if (L.deployedByNns(b, deployed.instances)) {", "if (true) {")], "mocks:B"),
  ("P15", "an unwound step keeps what it booked against the genesis neuron",
   [(R, "    takenFrom[k] -= amount;", "    takenFrom[k] -= 0;")], "mocks:R"),
  ("P16", "a destination changeable after its basket has started",
   [(L, "public func destinationChangeable(first : Nat, k : Nat, s : T.Status) : Bool { k == first and s == #Pending };", "public func destinationChangeable(first : Nat, k : Nat, s : T.Status) : Bool { true };")], "logic"),
  ("P17", "a basket of nine with a part below one minimum neuron kept at nine (not moved to rungs 1..8)",
   [(L, "        if (short) { count[full[f]] := NEURONS - 1; anyMoved := true; moved += 1 };", "        if (false) { count[full[f]] := NEURONS - 1; anyMoved := true; moved += 1 };")], "logic"),
  ("P18", "the entry holding a genesis neuron left to the rotating scan (every other share on that neuron waits until the cursor reaches it)",
   [(R, "    while (k < L.NEURONS and done < steps) {", "    while (false) {"),
    (R, "      if (actionable(i) and not heldOrWaiting(i)) {", "      if (actionable(i)) {")], "mocks:Q"),
  ("P19", "a holder below one minimum neuron kept in the table",
   [(L, "while (j < set.size()) { if (gross[j] >= u) List.add(keep, set[j]); j += 1 };", "while (j < set.size()) { List.add(keep, set[j]); j += 1 };")], "logic"),
  ("P20", "a basket of fewer than nine starting at rung 0 instead of rung 1",
   [(L, "firstRung = Array.tabulate<Nat>(m, func(x) { if (count[x] == NEURONS) 0 else 1 });", "firstRung = Array.tabulate<Nat>(m, func(x) { 0 });")], "logic"),
  ("P21", "the redistribution run once instead of until no holder drops out",
   [(L, "      if (List.size(keep) == set.size()) break redistribute;", "      if (List.size(keep) == set.size() or rounds >= 2) break redistribute;")], "logic"),
  ("P22", "the dropped holders left out of the table hash",
   [(L, "    for (d in dropped.values()) { who(d.owner); put(u64be(d.held)); put(u64be(d.staked)) };\n", "")], "logic"),
  ("P23", "a neuron counted against the minimum stake alone, without the Split fee",
   [(L, "    Nat.min(NEURONS, gross / unit(fee, minStake));", "    Nat.min(NEURONS, gross / minStake);")], "logic"),
  ("P24", "a smaller basket's rounding remainder put on its first part instead of its last",
   [(L, "    Array.tabulate<Nat>(n, func(j) { if (j + 1 == n) gross - q * (n - 1) else q });", "    Array.tabulate<Nat>(n, func(j) { if (j == 0) gross - q * (n - 1) else q });")], "logic"),
  ("P25", "the old rung-0 rule for changing a destination (a smaller basket, starting at rung 1, is locked from the start)",
   [(L, "public func destinationChangeable(first : Nat, k : Nat, s : T.Status) : Bool { k == first and s == #Pending };", "public func destinationChangeable(first : Nat, k : Nat, s : T.Status) : Bool { k == 0 and s == #Pending };")], "logic"),
  ("P26", "a neuron already at a part's id before its split taken as the part",
   [(R, "          case (?#Neuron(n)) {\n            List.add(foreign, { entry = i; rung = k; neuronId = child; stake = Nat64.toNat(n.cached_neuron_stake_e8s) });\n            Map.add(memoStep, Nat.compare, i * L.NEURONS + k, stepOf(i, k) + 1);\n            return #ok(",
        "          case (?#Neuron(_)) {\n            let bal = await* balanceOf(b, child);\n            if (bal + fee >= g) { takenFrom[k] += g; splits += 1; setStatus(i, #Split, ?child, null); return #ok(tag # \"already split off\") };\n            return #err(")], "mocks:G"),
  ("P27", "split memos by a public rule, (entry + 1) x 65,536 + k (moving on by step)",
   [(L, "    m | 0x8000_0000_0000_0000;", "    ignore m; Nat64.fromNat((entry + 1) * 65_536 + k + 9 * step);")], "mocks:G"),
  ("P28", "the secret seed left out of the split memo",
   [(L, "    for (c in s.values()) List.add(pre, c);\n", "")], "logic"),
  ("P29", "a part not moved to its next memo when its id is found occupied",
   [(R, "            Map.add(memoStep, Nat.compare, i * L.NEURONS + k, stepOf(i, k) + 1);\n", "")], "mocks:G"),
  ("P30", "a neuron found at a part's id not reported",
   [(R, "            List.add(foreign, { entry = i; rung = k; neuronId = child; stake = Nat64.toNat(n.cached_neuron_stake_e8s) });\n", "            ignore n;\n")], "mocks:G"),
  ("P31", "a part's id published before its split is sent",
   [(R, "            if (sent) { let m = memoOf(seed, i, k);", "            if (true) { let m = memoOf(seed, i, k);")], "mocks:G"),
  ("P32", "the memo seed drawn again on every tick (lost between steps)",
   [(R, "    if (memoSeed == null) {\n      let r = await mgmt().raw_rand();", "    if (true) {\n      let r = await mgmt().raw_rand();")], "mocks:G"),
]

def copy_tree(dst):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(here, dst, ignore=shutil.ignore_patterns(".git", "build", ".dfx"), symlinks=True)

def apply(dst, edits):
    for f, old, new in edits:
        p = os.path.join(dst, f)
        s = open(p).read()
        c = s.count(old)
        if c != 1:
            return "edit text found %d times in %s" % (c, f)
        open(p, "w").write(s.replace(old, new))
    return None

def run(dst, suite):
    src = subprocess.run("mops sources", shell=True, cwd=dst, capture_output=True, text=True).stdout.split()
    if suite == "logic":
        r = subprocess.run(["moc", "-r"] + src + ["test/run_tests.mo"], cwd=dst, capture_output=True, text=True, timeout=1200)
        out = r.stdout + r.stderr
        bad = r.returncode != 0 or "FAIL" in out
        lines = r.stdout.splitlines()
        part = ([l.split("  ")[0] for l in lines if l.startswith("PART ")] or ["before PART 1"])[-1]
        fails = [l.strip()[6:] for l in lines if l.strip().startswith("FAIL: ")]
        total = [l for l in lines if l.startswith("checks: ")]
        if fails:
            return bad, ("failed: " + "; ".join(fails))[:300]
        if r.returncode != 0:
            err = [l for l in r.stderr.splitlines() if "execution error" in l]
            return bad, ("trapped in " + part + ": " + (err[-1].split("execution error, ")[-1] if err else "nonzero exit"))[:300]
        return bad, (total[-1] if total else "no summary")[:300]
    os.makedirs(os.path.join(dst, "build"), exist_ok=True)
    r = subprocess.run(["moc", "-o", "build/redemption.wasm"] + src + [R], cwd=dst, capture_output=True, text=True, timeout=1200)
    if r.returncode != 0:
        return True, "does not compile: " + r.stderr.strip()[:160]
    env = dict(os.environ, MPV_GROUPS=suite.split(":")[1], MPV_HOLDER_WASM=os.path.join(dst, "build/redemption.wasm"),
               MPV_HOLDER_MOCKS_DIR=os.path.join(here, "build/test"), MPV_HOLDER_WORLD=os.environ["MOCKS_WORLD"])
    env.pop("MPV_REPORT_JSON", None)
    r = subprocess.run([os.environ["MOCKS_BIN"], "--nocapture", "--test-threads=1"], env=env, capture_output=True, text=True, timeout=3000)
    out = r.stdout + r.stderr
    red = [m.group(1) for m in (re.match(r"FAIL\s+(\S+)", l.strip()) for l in out.splitlines()) if m]
    detail = ("red: " + ", ".join(red)) if red else (out.strip().splitlines() or [""])[-1][:160]
    return r.returncode != 0, detail

rows = []
base = os.path.join(scratch, "baseline")
copy_tree(base)
for suite in sorted({f[3] for f in FAULTS if not only or f[0] in only}):
    bad, detail = run(base, suite)
    rows.append(("BASE", "unpatched tree on " + suite, "GREEN" if not bad else "RED", "GREEN", detail))
    print("BASE  %s: %s (%s)" % (suite, rows[-1][2], detail), flush=True)
for fid, what, edits, suite in FAULTS:
    if only and fid not in only:
        continue
    dst = os.path.join(scratch, fid)
    copy_tree(dst)
    err = apply(dst, edits)
    if err:
        rows.append((fid, what, "NOT APPLIED", "RED", err))
    else:
        bad, detail = run(dst, suite)
        rows.append((fid, what, "RED" if bad else "GREEN", "RED", suite + ": " + detail))
    print("%-5s %-11s %s | %s" % (fid, rows[-1][2], what, rows[-1][4]), flush=True)
    shutil.rmtree(dst, ignore_errors=True)
shutil.rmtree(base, ignore_errors=True)
ok = all(r[2] == r[3] for r in rows)
print("\n| id | fault | result | expected | evidence |\n|---|---|---|---|---|")
for r in rows:
    print("| %s | %s | %s | %s | %s |" % (r[0], r[1], r[2], r[3], r[4].replace("|", "/")))
print("\n%d rows, %s" % (len(rows), "all as expected" if ok else "NOT all as expected"))
sys.exit(0 if ok else 1)
PY

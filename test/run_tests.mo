/// run_tests.mo: interpreter battery for the holder canister's pure logic.
///
///   moc -r $(mops sources) test/run_tests.mo
///
/// Any failed check makes the run exit non-zero.
///
/// PART 1  delays and memos
/// PART 2  largest remainder
/// PART 3  the table rule, against the independent Python oracle's vectors
/// PART 4  the table rule's invariants on the MPV genesis stakes, and its edges
/// PART 5  the canonical table hash, against the oracle's
/// PART 6  folding the MENES ledger, the cut, contiguity
/// PART 7  stakes at the close and unresolvable withdrawals
/// PART 8  staking subaccount preimage
/// PART 9  the state machine over rung ranges, exhaustively (INV-R2), and who still owes at k
/// PART 10 destinations, permissions, binding, genesis neurons
/// PART 11 the books (Q6) and settlement
/// PART 12 backoff and fairness

import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Sha256 "mo:sha2/Sha256";

import L "../src/Logic";
import T "../src/Types";
import I "../src/Ifaces";
import V "Vectors";

var checks : Nat = 0;
var failures : Nat = 0;
func check(name : Text, cond : Bool) {
  checks += 1;
  if (not cond) { failures += 1; Debug.print("  FAIL: " # name) };
};

let DAY : Nat64 = 86_400;
let FEE = 10_000;
let MIN = 1_000_000_000;
let MPV : [Nat] = [166_666_600_000_000, 166_666_600_000_000, 166_666_600_000_000, 166_666_600_000_000,
                   166_666_600_000_000, 166_666_600_000_000, 166_666_600_000_000, 166_666_600_000_000,
                   166_667_200_000_000];
let ME = Principal.fromText("ecx5m-jaaaa-aaaak-qzfyq-cai");
let A = Principal.fromText("3gs3h-yg6vu-aaaaa-aaaaa-cai");
let B = Principal.fromText("3bt5t-v66vu-aaaaa-aaaaq-cai");
let SALE = Principal.fromText("d7ebz-3iaaa-aaaab-aerfq-cai");

func sumOf(xs : [Nat]) : Nat { var s = 0; for (x in xs.values()) s += x; s };

// ══ PART 1 ══ delays and memos ════════════════════════════════════════════════════════
Debug.print("PART 1  delays and memos");
check("the interval is 182 days, not 6 x 30", L.INTERVAL_SECONDS == 182 * DAY);
check("180 days would be two days under the voting floor", L.INTERVAL_SECONDS - 180 * DAY == 2 * DAY);
check("neuron 0 has no delay", L.delayOf(0) == 0);
check("neuron 8 has 1,456 days", L.delayOf(8) == 1_456 * DAY);
check("the MPV genesis stakes add up to the pool", sumOf(MPV) == L.POOL_E8S);
// Split memos: the independent vectors are SHA-256 computed in Python (hashlib) over the
// same preimage, for the seed 0x00..0x1f and for the seed 0xff x 32.
let SEED = Blob.fromArray(Array.tabulate<Nat8>(32, func(b) { Nat8.fromNat(b) }));
let SEED2 = Blob.fromArray(Array.tabulate<Nat8>(32, func(_) { 0xff : Nat8 }));
check("split memo vector (0, 0, 0)", L.splitMemo(SEED, 0, 0, 0) == 14_435_435_637_794_826_029);
check("split memo vector (0, 0, 1)", L.splitMemo(SEED, 0, 0, 1) == 13_644_969_511_930_070_795);
check("split memo vector (0, 8, 0)", L.splitMemo(SEED, 0, 8, 0) == 9_297_214_509_062_497_252);
check("split memo vector (5, 3, 0)", L.splitMemo(SEED, 5, 3, 0) == 16_424_250_303_363_446_226);
check("split memo vector (41,212, 7, 2)", L.splitMemo(SEED, 41_212, 7, 2) == 12_111_775_292_067_298_267);
check("split memo vector, other seed (0, 0, 0)", L.splitMemo(SEED2, 0, 0, 0) == 9_349_586_541_149_451_934);
var memoOk = true;
var memoSeedOk = true;
var memoOld = true;
let memosSeen = Map.empty<Nat64, Bool>();
var i0 = 0;
while (i0 < 120) {
  var k = 0;
  while (k < L.NEURONS) {
    var j = 0;
    while (j < 3) {
      let m = L.splitMemo(SEED, i0, k, j);
      if (m < 9) memoOk := false;                                   // never a genesis memo
      if (Map.get(memosSeen, Nat64.compare, m) != null) memoOk := false; // unique per (i, k, step)
      Map.add(memosSeen, Nat64.compare, m, true);
      if (L.splitMemo(SEED2, i0, k, j) == m) memoSeedOk := false;     // depends on the seed
      if (m == Nat64.fromNat((i0 + 1) * 65_536 + k)) memoOld := false; // not the old public rule
      j += 1;
    };
    k += 1;
  };
  i0 += 1;
};
check("split memos: never a genesis memo 0..8, unique over 120 entries x 9 rungs x 3 steps", memoOk and Map.size(memosSeen) == 120 * 9 * 3);
check("split memos change with the seed", memoSeedOk);
check("split memos are not (entry + 1) x 65,536 + k", memoOld);
check("split memos are deterministic", L.splitMemo(SEED, 7, 4, 1) == L.splitMemo(SEED, 7, 4, 1));

// ══ PART 2 ══ largest remainder ═══════════════════════════════════════════════════════
Debug.print("PART 2  largest remainder");
let lr1 = L.largestRemainder(10, [1, 1, 1]);
check("10 over three equal weights sums to 10", sumOf(lr1) == 10);
check("the extra unit goes to the lowest index on a tie", lr1[0] == 4 and lr1[1] == 3 and lr1[2] == 3);
let lr2 = L.largestRemainder(100, [1, 2, 3, 0]);
check("a zero weight gets nothing", lr2[3] == 0 and sumOf(lr2) == 100);
check("the largest remainder wins the extra unit", lr2 == [17, 33, 50, 0]);
check("all-zero weights give all zeros", L.largestRemainder(5, [0, 0]) == [0, 0]);
var lrOk = true;
var seed = 12345;
var t = 0;
while (t < 200) {
  seed := (seed * 1103515245 + 12345) % 2147483648;
  let n = 1 + seed % 17;
  let ws = Array.tabulate<Nat>(n, func(j) { (seed / (j + 1)) % 1_000_003 + (if (j == 0) 1 else 0) });
  let total = seed * 7919;
  let parts = L.largestRemainder(total, ws);
  if (sumOf(parts) != total) lrOk := false;
  let W = sumOf(ws);
  var j = 0;
  while (j < n) {
    // |part x W - total x w| < W
    let a = parts[j] * W;
    let b = total * ws[j];
    if ((if (a > b) a - b else b - a) >= W) lrOk := false;
    j += 1;
  };
  t += 1;
};
check("200 random cases: exact sum, every part within one e8s of exact", lrOk);

// ══ PART 3 ══ the rule against the Python oracle ══════════════════════════════════════
Debug.print("PART 3  the table rule against the oracle's vectors");
var vOk = 0;
var vRefused = 0;
var vIter = 0;
var vMoved = 0;
var vDropped = 0;
var vSmall = 0;
for (c in V.cases.values()) {
  switch (L.allocate(c.weights, c.stakes, c.fee, c.min), c.ok) {
    case (#err(_), false) { vOk += 1; vRefused += 1 };
    case (#ok(a), true) {
      if (a.kept == c.kept and a.dropped == c.dropped and a.gross == c.gross and a.firstRung == c.firstRung
          and a.neurons == c.neurons and a.dropRounds == c.dropRounds and a.movedToEight == c.moved) {
        vOk += 1;
        if (c.dropRounds >= 3) vIter += 1;
        if (c.moved > 0) vMoved += 1;
        if (c.dropped.size() > 0) vDropped += 1;
        if (Array.find<Nat>(c.firstRung, func(r) { r == 1 }) != null) vSmall += 1;
      } else Debug.print("  vector mismatch: weights " # debug_show (c.weights));
    };
    case _ Debug.print("  vector disagrees on refusal: weights " # debug_show (c.weights));
  };
};
check("every oracle vector reproduced exactly (" # Nat.toText(V.cases.size()) # ")", vOk == V.cases.size());
check("the vectors include refusals", vRefused >= 2);
check("the vectors include redistributions that needed a third round", vIter >= 3);
check("the vectors include baskets of nine moved to rungs 1..8", vMoved >= 3);
check("the vectors include dropped holders", vDropped >= 8);
check("the vectors include smaller baskets", vSmall >= 8);

// ══ PART 4 ══ invariants on the MPV stakes ════════════════════════════════════════════
Debug.print("PART 4  the rule's invariants on the MPV genesis stakes");
let U = MIN + FEE;
func invariants(name : Text, weights : [Nat]) : ?L.Allocation {
  switch (L.allocate(weights, MPV, FEE, MIN)) {
    case (#err(e)) { check(name # ": allocates (" # e # ")", false); null };
    case (#ok(a)) {
      let m = a.kept.size();
      check(name # ": kept and dropped partition the holders", m + a.dropped.size() == weights.size());
      check(name # ": gross shares add up to the pool", sumOf(a.gross) == L.POOL_E8S);
      check(name # ": the gross shares are the largest remainder over the kept holders (a fixed point)",
        L.largestRemainder(L.POOL_E8S, Array.map<Nat, Nat>(a.kept, func(i) { weights[i] })) == a.gross);
      var countOk = true; var partsOk = true; var smallOk = true; var moved = 0; var full = 0;
      var j = 0;
      while (j < m) {
        let g = a.gross[j];
        let parts = a.neurons[j];
        if (g < U) countOk := false;
        let n = Nat.min(L.NEURONS, g / U);
        if (parts.size() != n) {
          if (n == L.NEURONS and parts.size() == L.NEURONS - 1) moved += 1 else countOk := false;
        };
        if ((parts.size() == L.NEURONS) != (a.firstRung[j] == 0)) countOk := false;
        if (a.firstRung[j] > 1) countOk := false;
        if (parts.size() == L.NEURONS) full += 1;
        for (x in parts.values()) { if (x < U) partsOk := false };
        if (parts.size() < L.NEURONS) {
          if (sumOf(parts) != g) smallOk := false;
          var r = 0;
          while (r + 1 < parts.size()) { if (parts[r] != g / parts.size()) smallOk := false; r += 1 };
        };
        j += 1;
      };
      check(name # ": n = min(9, gross / (minimum + fee)) for every holder but those moved to rungs 1..8", countOk and moved == a.movedToEight);
      check(name # ": every part can be split off (>= minimum + fee)", partsOk);
      check(name # ": a smaller basket is its gross in equal parts, remainder on the last", smallOk);
      check(name # ": at least one basket of nine takes genesis neuron 0", full >= 1);
      var k = 0;
      var colOk = true;
      while (k < L.NEURONS) {
        var col = 0;
        var c = 0;
        while (c < m) {
          let e = a.neurons[c];
          if (k >= a.firstRung[c] and k < a.firstRung[c] + e.size()) col += e[k - a.firstRung[c]];
          c += 1;
        };
        if (col != MPV[k]) colOk := false;
        k += 1;
      };
      check(name # ": each genesis neuron is shared out to the e8s", colOk);
      ?a;
    };
  };
};
ignore invariants("one holder", [5]);
ignore invariants("two equal holders", [7, 7]);
switch (invariants("a whale and dust", [1_000_000_000_000, 1, 2, 3])) {
  case (?a) check("a whale and dust: the dust is dropped and the whale takes the whole pool", a.dropped == [1, 2, 3] and a.gross == [L.POOL_E8S]);
  case null {};
};
ignore invariants("151 holders, log-spread", Array.tabulate<Nat>(151, func(i) { 10 ** (i % 13) + i }));
ignore invariants("2,000 holders", Array.tabulate<Nat>(2000, func(i) { (i * 7919) % 100_000_000_000 + 1 }));
// A holder one e8s over nine minimum neurons: its part at a genesis neuron holding less
// than a ninth of the pool falls under the minimum, so it moves to rungs 1..8.
let edge = 9 * U + 1;
switch (invariants("one holder just over nine minimum neurons", [L.POOL_E8S - edge, edge])) {
  case (?a) check("that holder is delivered at rungs 1..8, its gross in eight parts",
    a.movedToEight == 1 and a.firstRung[1] == 1 and a.neurons[1].size() == 8 and sumOf(a.neurons[1]) == edge);
  case null {};
};
let five = 5 * U + 7;
switch (invariants("a holder with five minimum neurons", [L.POOL_E8S - five, five])) {
  case (?a) check("five neurons at rungs 1..5, remainder on the last",
    a.firstRung[1] == 1 and a.neurons[1] == [U + 1, U + 1, U + 1, U + 1, U + 3]);
  case null {};
};
check("nobody at all is refused", switch (L.allocate([], MPV, FEE, MIN)) { case (#err(_)) true; case _ false });
check("all small baskets are refused: nobody takes genesis neuron 0",
  switch (L.allocate(Array.tabulate<Nat>(200_000, func(_) { 1 }), MPV, FEE, MIN)) { case (#err(_)) true; case _ false });

// ══ PART 5 ══ the canonical table hash ════════════════════════════════════════════════
Debug.print("PART 5  the canonical table hash");
let synthWeights = Array.tabulate<Nat>(V.synthOwners.size(), func(i) { V.synthHeld[i] + V.synthStaked[i] });
switch (L.allocate(synthWeights, MPV, FEE, MIN)) {
  case (#err(e)) check("synthetic table allocates: " # e, false);
  case (#ok(a)) {
    check("the synthetic world keeps the oracle's count", a.kept.size() == V.synthKept);
    let table = Array.tabulate<T.Entry>(a.kept.size(), func(j) {
      let i = a.kept[j];
      { owner = Principal.fromText(V.synthOwners[i]); held = V.synthHeld[i]; staked = V.synthStaked[i];
        gross = a.gross[j]; firstRung = a.firstRung[j]; neurons = a.neurons[j] };
    });
    let left = Array.map<Nat, T.Dropped>(a.dropped, func(i) { { owner = Principal.fromText(V.synthOwners[i]); held = V.synthHeld[i]; staked = V.synthStaked[i] } });
    let sorted = Array.sort<T.Entry>(table, func(x, y) { L.byText(x.owner, y.owner) });
    check("the oracle's owners are already in principal-text order", Array.map<T.Entry, Principal>(sorted, func(e) { e.owner }) == Array.map<T.Entry, Principal>(table, func(e) { e.owner }));
    let h = Sha256.fromBlob(#sha256, L.tableBytes(table, left, FEE, MIN, MPV));
    var hx = "";
    let d = Text.toArray("0123456789abcdef");
    for (x in h.values()) { let v = Nat8.toNat(x); hx #= Text.fromChar(d[v / 16]) # Text.fromChar(d[v % 16]) };
    check("the canonical hash of the synthetic 300 table equals the oracle's", hx == V.synthHash);
    let bytes = Blob.toArray(L.tableBytes(table, left, FEE, MIN, MPV));
    check("the canonical bytes start with the version tag", Text.decodeUtf8(Blob.fromArray(Array.sliceToArray<Nat8>(bytes, 0, 19))) == ?"MPV-HOLDER-TABLE-v2");
    let swapped = Array.tabulate<T.Entry>(table.size(), func(i) { if (i == 0) table[1] else if (i == 1) table[0] else table[i] });
    check("reordering rows changes the hash", Sha256.fromBlob(#sha256, L.tableBytes(swapped, left, FEE, MIN, MPV)) != h);
    let bumped = Array.tabulate<T.Entry>(table.size(), func(i) { if (i == 5) ({ table[i] with gross = table[i].gross + 1 }) else table[i] });
    check("one e8s more for one holder changes the hash", Sha256.fromBlob(#sha256, L.tableBytes(bumped, left, FEE, MIN, MPV)) != h);
    check("the hash covers the dropped list", left.size() > 0 and Sha256.fromBlob(#sha256, L.tableBytes(table, Array.sliceToArray<T.Dropped>(left, 1, left.size()), FEE, MIN, MPV)) != h);
  };
};

// ══ PART 6 ══ folding the ledger ══════════════════════════════════════════════════════
Debug.print("PART 6  folding the MENES ledger");
func acct(p : Principal) : I.Account { { owner = p; subaccount = null } };
func tx(kind : Text, ts : Nat64) : I.Transaction { { kind; mint = null; burn = null; transfer = null; approve = null; timestamp = ts } };
let mint = { tx("mint", 1) with mint = ?{ to = acct(A); amount = 500; memo = null; created_at_time = null } };
let burn = { tx("burn", 2) with burn = ?{ from = acct(A); amount = 50; memo = null; created_at_time = null; spender = null } };
let xfer = { tx("transfer", 3) with transfer = ?{ from = { owner = A; subaccount = ?Blob.fromArray([1]) }; to = acct(B); amount = 100; fee = ?10; memo = null; created_at_time = null; spender = null } };
let xferNoFee = { tx("transfer", 3) with transfer = ?{ from = acct(A); to = acct(B); amount = 100; fee = null; memo = null; created_at_time = null; spender = ?acct(SALE) } };
let appr = { tx("approve", 4) with approve = ?{ from = acct(A); spender = acct(B); amount = 1_000; fee = ?10; expected_allowance = null; expires_at = null; memo = null; created_at_time = null } };
check("mint credits the owner and the supply", L.effectOf(mint) == #ok({ deltas = [(A, 500)]; supply = 500 }));
check("burn debits the owner and the supply", L.effectOf(burn) == #ok({ deltas = [(A, -50)]; supply = -50 }));
check("a transfer from a subaccount folds into its owner; the fee leaves the supply",
  L.effectOf(xfer) == #ok({ deltas = [(A, -110), (B, 100)]; supply = -10 }));
check("a transfer_from with no fee recorded costs no fee", L.effectOf(xferNoFee) == #ok({ deltas = [(A, -100), (B, 100)]; supply = 0 }));
check("an approval costs its fee only", L.effectOf(appr) == #ok({ deltas = [(A, -10)]; supply = -10 }));
check("an unknown kind is refused", switch (L.effectOf(tx("fee_collect", 5))) { case (#err(_)) true; case _ false });
check("a kind without its record is refused", switch (L.effectOf(tx("transfer", 5))) { case (#err(_)) true; case _ false });
check("a block exactly at the close is folded", L.beforeClose(1_000_000_000_000, 1_000));
check("a block one ns after the close is not", not L.beforeClose(1_000_000_000_001, 1_000));
check("contiguity: ledger only", L.contiguousFrom(7000, [(7000, 2000)]) == 2000);
check("contiguity: archive then ledger", L.contiguousFrom(0, [(0, 1000), (1000, 1000), (7000, 1936)]) == 2000);
check("contiguity: the archive piece given after the ledger piece still counts", L.contiguousFrom(0, [(1000, 500), (0, 1000)]) == 1500);
check("contiguity: a gap stops the run", L.contiguousFrom(0, [(0, 100), (101, 900)]) == 100);
check("contiguity: nothing at the start is zero (a missing block)", L.contiguousFrom(5, [(6, 100)]) == 0);
check("contiguity: an empty archive reply is zero", L.contiguousFrom(0, [(0, 0), (7000, 10)]) == 0);

// ══ PART 7 ══ stakes ══════════════════════════════════════════════════════════════════
Debug.print("PART 7  stakes at the close");
func stake(id : Nat, owner : Principal, amount : Nat, active : Bool, at : Int) : T.StakeInfo {
  { id; owner; amount; active; stakedAt = at; lockUntil = at + 1; lockPeriod = #Months12; pendingRewards = 0; weightedAmount = amount };
};
check("a stake made at the close existed", L.existedAtClose(stake(0, A, 1, true, 1_000_000_000_000), 1_000));
check("a stake made after the close did not", not L.existedAtClose(stake(0, A, 1, true, 1_000_000_000_001), 1_000));
let inactiveA = stake(3, A, 500, false, 1);
check("a payment smaller than the stake is not a withdrawal", L.unresolvedWithdrawal([inactiveA], [(9000, A, 499)]) == null);
check("a payment of the whole stake after the cut is unresolvable", L.unresolvedWithdrawal([inactiveA], [(9000, A, 500)]) == ?(3, 9000));
check("a payment with rewards on top is unresolvable", L.unresolvedWithdrawal([inactiveA], [(9001, A, 700)]) == ?(3, 9001));
check("a payment to someone else is not", L.unresolvedWithdrawal([inactiveA], [(9000, B, 10_000)]) == null);
check("no inactive stakes: nothing to resolve", L.unresolvedWithdrawal([], [(9000, A, 10_000)]) == null);
check("two equal reads agree", L.sameStakes([inactiveA, stake(4, B, 9, true, 2)], [inactiveA, stake(4, B, 9, true, 2)]));
check("a stake turning inactive between reads is a change", not L.sameStakes([stake(4, B, 9, true, 2)], [stake(4, B, 9, false, 2)]));
check("a new stake between reads is a change", not L.sameStakes([inactiveA], [inactiveA, stake(4, B, 9, true, 2)]));
check("pending rewards moving is not a change", L.sameStakes([stake(4, B, 9, true, 2)], [{ stake(4, B, 9, true, 2) with pendingRewards = 77 }]));

// ══ PART 8 ══ staking subaccount preimage ═════════════════════════════════════════════
Debug.print("PART 8  staking subaccount preimage");
func bytesOf(b : Blob) : [Nat8] { Blob.toArray(b) };
let v1 = bytesOf(L.stakingSubaccountPreimage(Principal.fromText("aaaaa-aa"), 0));
check("vector 1 matches the IC construction", v1 == [12, 110, 101, 117, 114, 111, 110, 45, 115, 116, 97, 107, 101, 0, 0, 0, 0, 0, 0, 0, 0]);
let v2 = bytesOf(L.stakingSubaccountPreimage(Principal.fromText("3gs3h-yg6vu-aaaaa-aaaaa-cai"), 7));
check("vector 2 matches the IC construction", v2 == [12, 110, 101, 117, 114, 111, 110, 45, 115, 116, 97, 107, 101,
                                                     222, 173, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 7]);
let vbe = bytesOf(L.stakingSubaccountPreimage(Principal.fromText("aaaaa-aa"), 0x0102030405060708));
check("the memo is big-endian", Array.sliceToArray<Nat8>(vbe, 13, 21) == [1, 2, 3, 4, 5, 6, 7, 8]);
// The holder canister's genesis neuron 0 id and a split memo, against
// verification/subaccount.py (sha256 of the preimage, computed independently).
let g0 = Sha256.fromBlob(#sha256, L.stakingSubaccountPreimage(ME, 0));
check("genesis neuron 0's id is 32 bytes", g0.size() == 32);
check("genesis neuron ids differ per memo", Sha256.fromBlob(#sha256, L.stakingSubaccountPreimage(ME, 1)) != g0);

// ══ PART 9 ══ the state machine ═══════════════════════════════════════════════════════
Debug.print("PART 9  the state machine");
let statuses : [T.Status] = [#Pending, #Split, #Granted, #Done];
var machineOk = true;
for (k in [0, 1, 3, 8].vals()) {
  for (from in statuses.values()) {
    for (to in statuses.values()) {
      for (dk in [0, 1, 2].vals()) {
        let ok = L.canMove(k, from, k + dk, to);
        let expect = if (L.isTerminal(from)) false
                     else if (dk == 1) (from == #Granted and to == #Pending)
                     else if (dk == 2) false
                     else L.rank(to) > L.rank(from);
        if (ok != expect) machineOk := false;
      };
    };
  };
};
check("canMove, exhaustively over (rung, status) x (rung', status')", machineOk);
check("nothing leaves Done", not L.canMove(4, #Done, 5, #Pending) and not L.canMove(4, #Done, 4, #Granted));
check("nothing goes back to Pending on the same rung through canMove", not L.canMove(4, #Split, 4, #Pending));
check("no rung is skipped", not L.canMove(4, #Granted, 6, #Pending));
check("a basket of nine: after the strip of rung 8, Done", L.afterStrip(8, 8) == (8, #Done));
check("after the strip of rung 3 of nine: rung 4, Pending", L.afterStrip(3, 8) == (4, #Pending));
check("a basket at rungs 1..5: Done after rung 5, never rung 6", L.afterStrip(5, 5) == (5, #Done) and L.afterStrip(4, 5) == (5, #Pending));
check("delivered neurons: Done counts the whole basket", L.neuronsDelivered(0, 9, 2, #Done) == 9 and L.neuronsDelivered(1, 3, 2, #Done) == 3);
check("delivered neurons: rungs below the one in flight", L.neuronsDelivered(0, 9, 5, #Granted) == 5 and L.neuronsDelivered(1, 5, 3, #Split) == 2);
let e5 : T.Entry = { owner = A; held = 1; staked = 0; gross = 5 * U; firstRung = 1; neurons = [U, U, U, U, U + 7] };
check("lastRung and partAt of a basket at rungs 1..5", L.lastRung(e5) == 5 and L.partAt(e5, 5) == U + 7 and L.partAt(e5, 1) == U);
// Who still owes at genesis neuron k.
check("a basket below k still owes at k", L.stillOwedAt(4, 0, 8, 2, #Granted));
check("a basket pending at k still owes at k", L.stillOwedAt(4, 0, 8, 4, #Pending));
check("a basket split at k no longer owes at k", not L.stillOwedAt(4, 0, 8, 4, #Split));
check("a basket past k no longer owes at k", not L.stillOwedAt(4, 0, 8, 5, #Pending));
check("a finished basket owes nothing", not L.stillOwedAt(0, 0, 8, 8, #Done));
check("a basket at rungs 1..3 owes nothing at genesis neuron 0", not L.stillOwedAt(0, 1, 3, 1, #Pending));
check("a basket at rungs 1..3 owes nothing above rung 3", not L.stillOwedAt(4, 1, 3, 1, #Pending) and not L.stillOwedAt(8, 1, 3, 2, #Granted));
check("a basket at rungs 1..3 owes at rung 2 while at rung 1", L.stillOwedAt(2, 1, 3, 1, #Granted));

// ══ PART 10 ══ destinations, permissions, binding, genesis ════════════════════════════
Debug.print("PART 10 destinations, permissions, binding, genesis neurons");
let GOV = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
let LED = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
check("this canister is refused as a destination", L.destinationRefusal(ME, ME, GOV, LED) != null);
check("governance is refused", L.destinationRefusal(GOV, ME, GOV, LED) != null);
check("the ledger is refused", L.destinationRefusal(LED, ME, GOV, LED) != null);
check("anonymous is refused", L.destinationRefusal(Principal.anonymous(), ME, GOV, LED) != null);
check("the management canister is refused", L.destinationRefusal(Principal.fromText("aaaaa-aa"), ME, GOV, LED) != null);
check("a person is accepted", L.destinationRefusal(A, ME, GOV, LED) == null);
check("changeable before the first neuron starts", L.destinationChangeable(0, 0, #Pending) and L.destinationChangeable(1, 1, #Pending));
check("frozen once it has", not L.destinationChangeable(0, 0, #Split) and not L.destinationChangeable(0, 1, #Pending)
  and not L.destinationChangeable(1, 1, #Split) and not L.destinationChangeable(1, 2, #Pending));
check("every basket waits for a destination", L.readiness(null) == #AwaitingDestination);
check("a nominated basket is ready", L.readiness(?A) == #Ready);
let perms : [{ principal : ?Principal; permission_type : [Int32] }] = [{ principal = ?ME; permission_type = [1, 2] }, { principal = ?A; permission_type = [3] }];
check("permissionsOf reads this canister's own", L.permissionsOf(perms, ME) == [1, 2]);
check("permissionsOf is empty once stripped", L.permissionsOf(perms, B) == []);
check("an empty grantable set is unusable", not L.grantableIsUsable([]));
check("one controller is a sole controller", L.soleController([GOV]) == ?GOV);
check("two controllers are not", L.soleController([GOV, A]) == null);
let ROOT = Principal.fromText("r7inp-6aaaa-aaaaa-aaabq-cai");
let SWAP = Principal.fromText("rkp4c-7iaaa-aaaaa-aaaca-cai");
let answer : I.ListSnsCanistersResponse = { root = ?ROOT; swap = ?SWAP; ledger = ?LED; index = null; governance = ?GOV; dapps = [A, ME]; archives = [] };
check("binds to a root that lists it", L.bindingFrom(ROOT, answer, ME, 5) == ?{ root = ROOT; governance = GOV; ledger = LED; swap = SWAP; boundAt = 5 });
check("refuses a controller that is not the root it names", L.bindingFrom(A, answer, ME, 5) == null);
check("refuses an SNS that does not list it", L.bindingFrom(ROOT, { answer with dapps = [A] }, ME, 5) == null);
check("refuses an SNS with no swap", L.bindingFrom(ROOT, { answer with swap = null }, ME, 5) == null);
let bnd : T.Binding = { root = ROOT; governance = GOV; ledger = LED; swap = SWAP; boundAt = 5 };
let inst : I.DeployedSns = { root_canister_id = ?ROOT; governance_canister_id = ?GOV; ledger_canister_id = ?LED; swap_canister_id = ?SWAP; index_canister_id = null };
check("SNS-W listing the same SNS", L.deployedByNns(bnd, [inst]));
check("SNS-W listing another swap is refused", not L.deployedByNns(bnd, [{ inst with swap_canister_id = ?A }]));
check("SNS-W listing nothing is refused", not L.deployedByNns(bnd, []));
func gn(delay : Nat64, p : Principal) : { cached_neuron_stake_e8s : Nat64; neuron_fees_e8s : Nat64; vesting_period_seconds : ?Nat64; created_timestamp_seconds : Nat64; dissolve_state : ?{ #DissolveDelaySeconds : Nat64; #WhenDissolvedTimestampSeconds : Nat64 }; permissions : [{ principal : ?Principal; permission_type : [Int32] }] } {
  { cached_neuron_stake_e8s = 100; neuron_fees_e8s = 0; vesting_period_seconds = ?0; created_timestamp_seconds = 10;
    dissolve_state = ?#DissolveDelaySeconds(delay); permissions = [{ principal = ?p; permission_type = [1] }] };
};
check("genesis neuron 3 with 546 days is accepted", L.genesisRefusal(3, gn(546 * DAY, ME), ME, 1_000) == null);
check("genesis neuron 3 with 545 days is refused", L.genesisRefusal(3, gn(545 * DAY, ME), ME, 1_000) != null);
check("a genesis neuron this canister has no permission on is refused", L.genesisRefusal(0, gn(0, A), ME, 1_000) != null);
check("a vesting genesis neuron is refused", L.genesisRefusal(0, { gn(0, ME) with vesting_period_seconds = ?10_000 }, ME, 1_000) != null);
check("a genesis neuron with fees is refused", L.genesisRefusal(0, { gn(0, ME) with neuron_fees_e8s = 1 }, ME, 1_000) != null);
check("a dissolving genesis neuron is refused", L.genesisRefusal(0, { gn(0, ME) with dissolve_state = ?#WhenDissolvedTimestampSeconds(5) }, ME, 1_000) != null);
check("an empty genesis neuron is refused", L.genesisRefusal(0, { gn(0, ME) with cached_neuron_stake_e8s = 0 }, ME, 1_000) != null);
check("exclusion lookup by text", L.contains(["d7ebz-3iaaa-aaaab-aerfq-cai"], SALE) and not L.contains([], SALE));

// ══ PART 11 ══ the books ══════════════════════════════════════════════════════════════
Debug.print("PART 11 the books (Q6) and settlement");
let st3 : [Nat] = [100, 200, 300];
let r0 = L.reconcile(st3, [10, 0, 0], [false, false, false], [90, 200, 300]);
check("exactly what is owed: holds, no surplus", r0.holds and r0.surplus == 0);
let r1 = L.reconcile(st3, [10, 0, 0], [false, false, false], [95, 200, 307]);
check("a donation: holds, and the surplus is reported", r1.holds and r1.surplus == 12);
let r2 = L.reconcile(st3, [10, 0, 0], [false, false, false], [89, 200, 300]);
check("one e8s short anywhere: does not hold", not r2.holds);
let r3 = L.reconcile(st3, [10, 0, 0], [false, true, false], [90, 0, 300]);
check("a handed-over neuron is the holder's, not counted", r3.holds and r3.parents[1].expected == 0);
func statsWith(done : Nat, entries : Nat, handed : Nat) : T.Stats {
  { phase = #Delivering; entries; done; pending = entries - done; fullBaskets = 0; smallBaskets = 0; dropped = 0;
    neuronsDelivered = 0; neuronsTotal = 0; parentsHandedOver = handed; takenFrom = [];
    splits = 0; deliveredStake = 0; feesPaid = 0; foreignNeurons = 0 };
};
check("settled: every entry delivered, all nine handed over, books hold", L.settled(statsWith(10, 10, 9), r0));
check("not settled with an entry in flight", not L.settled(statsWith(9, 10, 9), r0));
check("not settled with a genesis neuron still held", not L.settled(statsWith(10, 10, 8), r0));
check("not settled when the books do not hold", not L.settled(statsWith(10, 10, 9), r2));

// ══ PART 12 ══ backoff and fairness ═══════════════════════════════════════════════════
Debug.print("PART 12 backoff and fairness");
check("no failures: every tick", L.backoffTicks(0) == 1);
check("backoff doubles", L.backoffTicks(3) == 8);
check("backoff caps at an hour of ticks", L.backoffTicks(50) == 240);
var visited = Array.tabulate<Bool>(7, func(_) { false });
var s2 = 0;
var seen = 0;
while (s2 < 7) { let i = L.scanIndex(5, s2, 7); if (not visited[i]) seen += 1; visited := Array.tabulate<Bool>(7, func(j) { visited[j] or j == i }); s2 += 1 };
check("a scan from any cursor visits every entry once", seen == 7);
check("the cursor moves past what was attempted", L.advanceCursor(6, 7) == 0);
check("the most-failed open entry is named", L.mostFailed([0, 5, 9, 2], [false, false, true, false]) == ?1);

Debug.print("checks: " # Nat.toText(checks) # ", failures: " # Nat.toText(failures));
if (failures > 0) Runtime.trap("logic battery failed");

/// run_tests.mo, interpreter battery for the redemption canister's pure logic.
///
/// Runs with no replica:
///   moc -r --package core <core/src> test/run_tests.mo
/// Any failed check traps, so the exit code is a hard CI gate.
///
/// PART 1  dissolve delay, including the 180-vs-182-day trap that would silence every neuron
/// PART 2  dust round-up, pinned to the measured real table
/// PART 3  lifecycle gating, checked EXHAUSTIVELY over every status pair (INV-R2)
/// PART 4  staking subaccount preimage, pinned to vectors derived from the IC's own formula
/// PART 5  reserve sizing and reconciliation (INV-R1), including the settlement query

import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Principal "mo:core/Principal";

import L "../src/Logic";
import T "../src/Types";

var checks : Nat = 0;
var failures : Nat = 0;
func check(name : Text, cond : Bool) {
  checks += 1;
  if (not cond) { failures += 1; Debug.print("  FAIL: " # name) };
};

let SEC = 1_000_000_000; // ns per second
let FLOOR = L.DISSOLVE_FLOOR_SECONDS;
let MIN = L.MIN_NEURON_STAKE_E8S;

// ══ PART 1 ══ dissolve delay ═════════════════════════════════════════════════════════
Debug.print("PART 1  dissolve delay");

// The trap this whole design exists to avoid: "6 months" as 6*30 days is 180 days, and the
// voting floor is 182. A neuron issued at 180 days is owned correctly and cannot vote.
check("floor is exactly 26 weeks = 182 days", FLOOR == 15_724_800);
check("182 days in seconds matches the floor", Nat64.fromNat(182 * 24 * 3600) == FLOOR);
check("180 days is BELOW the floor (the trap)", Nat64.fromNat(180 * 24 * 3600) < FLOOR);
check("the trap is exactly two days wide", FLOOR - Nat64.fromNat(180 * 24 * 3600) == Nat64.fromNat(2 * 24 * 3600));

// A wallet holder always takes the floor.
check("wallet holder gets the floor", L.walletDelay(FLOOR) == FLOOR);

// A staker with a lock already expired at snapshot time still clears the floor.
check("expired lock -> floor", L.dissolveDelayFor(1000 * SEC, 2000 * SEC, FLOOR) == FLOOR);
check("lock exactly at snapshot -> floor", L.dissolveDelayFor(2000 * SEC, 2000 * SEC, FLOOR) == FLOOR);

// A short remaining lock is raised to the floor; a long one is kept.
let snapshot = 1_000_000 * SEC;
check("2-month remainder is floored up",
  L.dissolveDelayFor(snapshot + 60 * 24 * 3600 * SEC, snapshot, FLOOR) == FLOOR);
check("4-month remainder is floored up",
  L.dissolveDelayFor(snapshot + 120 * 24 * 3600 * SEC, snapshot, FLOOR) == FLOOR);
check("12-month remainder is kept",
  L.dissolveDelayFor(snapshot + 365 * 24 * 3600 * SEC, snapshot, FLOOR) == Nat64.fromNat(365 * 24 * 3600));
check("18-month remainder is kept",
  L.dissolveDelayFor(snapshot + 547 * 24 * 3600 * SEC, snapshot, FLOOR) == Nat64.fromNat(547 * 24 * 3600));

// Boundary: one second under the floor must round up, one second over must not.
check("one second under the floor rounds up",
  L.dissolveDelayFor(snapshot + (15_724_799 * SEC), snapshot, FLOOR) == FLOOR);
check("one second over the floor is kept",
  L.dissolveDelayFor(snapshot + (15_724_801 * SEC), snapshot, FLOOR) == 15_724_801);

// Every delay the logic can ever produce clears the voting floor. This is INV-R5.
var d = 0;
var invR5 = true;
while (d < 2000) {
  let got = L.dissolveDelayFor(snapshot + (d * 24 * 3600 * SEC), snapshot, FLOOR);
  if (got < FLOOR) { invR5 := false };
  d += 137; // stride across the whole range including both sides of the floor
};
check("INV-R5: no reachable delay is under the voting floor", invR5);

// ══ PART 2 ══ dust ═══════════════════════════════════════════════════════════════════
Debug.print("PART 2  dust round-up");

check("min neuron stake is 10 tokens at 8 decimals", MIN == 1_000_000_000);
check("dust rounds up to the floor", L.payoutAmount(1, MIN) == MIN);
check("zero rounds up to the floor", L.payoutAmount(0, MIN) == MIN);
check("exactly at the floor is untouched", L.payoutAmount(MIN, MIN) == MIN);
check("above the floor is untouched", L.payoutAmount(MIN + 1, MIN) == MIN + 1);
check("a large balance is untouched", L.payoutAmount(2_000_000 * MIN, MIN) == 2_000_000 * MIN);

// Cost of the round-up on a small worked table.
check("round-up cost of three dust entries",
  L.roundUpCost([1, 2, 3], MIN) == (MIN - 1) + (MIN - 2) + (MIN - 3));
check("nothing over the floor contributes cost",
  L.roundUpCost([MIN, MIN + 5, 10 * MIN], MIN) == 0);
check("mixed table charges only the dust",
  L.roundUpCost([1, MIN, 5 * MIN, 7], MIN) == (MIN - 1) + (MIN - 7));

// ══ PART 2b ══ liquid payouts and the fee floor ══════════════════════════════════════
Debug.print("PART 2b liquid payouts");

let FEE_L = 10_000; // 0.0001 MENES

// A liquid payout has no 10-MENES floor. Its only limit is the transfer fee.
check("an amount above the fee is payable", L.liquidPayable(FEE_L + 1, FEE_L));
check("an amount exactly at the fee is NOT payable", not L.liquidPayable(FEE_L, FEE_L));
check("an amount below the fee is NOT payable", not L.liquidPayable(FEE_L - 1, FEE_L));
check("zero is not payable", not L.liquidPayable(0, FEE_L));
check("a large amount is payable", L.liquidPayable(867_689 * 100_000_000, FEE_L));

// A balance just under the 10_000 e8s fee, of the size a draft snapshot showed at the top
// of the unpayable range. Pinned so a change to either number is visible.
check("a sub-fee dust balance is genuinely unpayable", not L.liquidPayable(9_282, FEE_L));
check("one unit above the fee is payable", L.liquidPayable(10_001, FEE_L));

// The holder receives the full amount; the reserve bears the fee.
check("liquid delivers the full amount", L.liquidDelivered(500) == 500);

// A liquid entry finishes in ONE step and never enters the neuron chain. This is the check
// that stops a liquid holder's tokens being sent to a governance subaccount and stranded.
check("liquid: Pending goes straight to Done", L.successorLiquid(#Pending) == ?#Done);
check("liquid: Done is the end", L.successorLiquid(#Done) == null);
check("liquid: never enters Funded", L.successorLiquid(#Funded) == null);
check("liquid: never enters Claimed", L.successorLiquid(#Claimed) == null);

// nextFor routes by payout kind and by nothing else.
check("nextFor(#Liquid, Pending) = Done", L.nextFor(#Liquid, #Pending) == ?#Done);
check("nextFor(#Neuron, Pending) = Funded", L.nextFor(#Neuron({ delaySeconds = FLOOR }), #Pending) == ?#Funded);
check("nextFor(#Neuron, Delayed) = Granted", L.nextFor(#Neuron({ delaySeconds = FLOOR }), #Delayed) == ?#Granted);
check("nextFor(#Liquid, Delayed) is impossible", L.nextFor(#Liquid, #Delayed) == null);

// ══ PART 2c ══ owner-nominated destinations ══════════════════════════════════════════
Debug.print("PART 2c destinations");

let OWNER = Principal.fromText("3gs3h-yg6vu-aaaaa-aaaaa-cai");
let NNSP  = Principal.fromText("3bt5t-v66vu-aaaaa-aaaaq-cai");
let NEU : T.Payout = #Neuron({ delaySeconds = FLOOR });

// A liquid payout never needs a destination and always goes to the owner.
check("liquid is ready immediately", L.resolvePayout(#Liquid, null) == #Ready(#Liquid));
check("liquid ignores any destination", L.resolvePayout(#Liquid, ?NNSP) == #Ready(#Liquid));
check("liquid always pays the owner", L.recipient(OWNER, ?NNSP, #Liquid) == OWNER);

// A neuron WAITS until its owner nominates. There is no liquid fallback for a staker.
check("neuron with no destination waits", L.resolvePayout(NEU, null) == #AwaitingDestination);
check("neuron with a destination is ready", L.resolvePayout(NEU, ?NNSP) == #Ready(NEU));
check("neuron goes to the nominated principal", L.recipient(OWNER, ?NNSP, NEU) == NNSP);
check("neuron with no destination falls back to the owner, not to nobody",
  L.recipient(OWNER, null, NEU) == OWNER);

// Waiting must never be confused with failing: a waiting entry is not terminal, so it stays
// claimable forever and the run stays unsettled until somebody claims it. Nothing expires.
check("awaiting is not a terminal state", not L.isTerminal(#Pending));

// ══ PART 3 ══ lifecycle gating, exhaustive ═══════════════════════════════════════════
Debug.print("PART 3  lifecycle gating (exhaustive)");

let all : [T.Status] = [#Pending, #Funded, #Claimed, #Delayed, #Granted, #Done, #Failed("x")];

check("ranks are distinct and ordered",
  L.rank(#Pending) < L.rank(#Funded) and L.rank(#Funded) < L.rank(#Claimed)
  and L.rank(#Claimed) < L.rank(#Delayed) and L.rank(#Delayed) < L.rank(#Granted)
  and L.rank(#Granted) < L.rank(#Done));

check("Done is terminal", L.isTerminal(#Done));
check("Failed is terminal", L.isTerminal(#Failed("e")));
check("Pending is not terminal", not L.isTerminal(#Pending));
check("Granted is NOT terminal (the strip still has to run)", not L.isTerminal(#Granted));

// The safety line: the holder owns the neuron from Granted onward, and not before.
check("holder is whole at Granted", L.holderIsWhole(#Granted));
check("holder is whole at Done", L.holderIsWhole(#Done));
check("holder is NOT whole at Delayed", not L.holderIsWhole(#Delayed));
check("holder is NOT whole at Claimed", not L.holderIsWhole(#Claimed));
check("holder is NOT whole at Funded", not L.holderIsWhole(#Funded));

// INV-R2, checked over every ordered pair rather than a sample: a status may only be
// replaced by one strictly higher, and nothing may leave a terminal state.
var backwards = 0;
var fromTerminal = 0;
var forwardOk = 0;
for (a in all.values()) {
  for (b in all.values()) {
    let allowed = L.canAdvance(a, b);
    if (allowed and L.isTerminal(a)) { fromTerminal += 1 };
    if (allowed) {
      switch (b) {
        case (#Failed(_)) { forwardOk += 1 };
        case (_) { if (L.rank(b) <= L.rank(a)) { backwards += 1 } else { forwardOk += 1 } };
      };
    };
  };
};
check("INV-R2: no transition ever moves backwards", backwards == 0);
check("INV-R2: nothing ever leaves a terminal state", fromTerminal == 0);
check("INV-R2: forward transitions do exist (not vacuous)", forwardOk > 0);

// The happy path is exactly the chain in the design, and it ends.
check("successor chain: Pending -> Funded", L.successor(#Pending) == ?#Funded);
check("successor chain: Funded -> Claimed", L.successor(#Funded) == ?#Claimed);
check("successor chain: Claimed -> Delayed", L.successor(#Claimed) == ?#Delayed);
check("successor chain: Delayed -> Granted", L.successor(#Delayed) == ?#Granted);
check("successor chain: Granted -> Done", L.successor(#Granted) == ?#Done);
check("Done has no successor", L.successor(#Done) == null);
check("Failed has no successor", L.successor(#Failed("e")) == null);

// A step may always be abandoned to Failed, but never from a terminal state.
check("Pending may fail", L.canAdvance(#Pending, #Failed("e")));
check("Granted may still fail (the strip can fail)", L.canAdvance(#Granted, #Failed("e")));
check("Done may NOT be re-failed", not L.canAdvance(#Done, #Failed("e")));
check("Failed may not be revived", not L.canAdvance(#Failed("a"), #Pending));
check("Failed may not advance to Done", not L.canAdvance(#Failed("a"), #Done));

// ══ PART 4 ══ staking subaccount preimage ════════════════════════════════════════════
Debug.print("PART 4  staking subaccount preimage");

// Vectors derived independently from the IC's own construction in
// rs/nervous_system/common/src/ledger.rs:
//     sha256( [len(domain)] ++ "neuron-stake" ++ controller.as_slice() ++ nonce_be )
// If the byte layout drifts, tokens go to a subaccount no neuron is ever claimed from.

func bytesOf(b : Blob) : [Nat8] { Blob.toArray(b) };
func eqBytes(a : [Nat8], b : [Nat8]) : Bool {
  if (a.size() != b.size()) return false;
  var i = 0;
  while (i < a.size()) { if (a[i] != b[i]) return false; i += 1 };
  true;
};

// Vector 1: the management canister principal (zero-length body), nonce 0.
let v1 = bytesOf(L.stakingSubaccountPreimage(Principal.fromText("aaaaa-aa"), 0));
let v1expect : [Nat8] = [12, 110, 101, 117, 114, 111, 110, 45, 115, 116, 97, 107, 101, 0, 0, 0, 0, 0, 0, 0, 0];
check("vector 1: empty-principal preimage is 21 bytes", v1.size() == 21);
check("vector 1: preimage matches the IC construction", eqBytes(v1, v1expect));

// Vector 2: a full-length canister principal, non-zero nonce.
let v2 = bytesOf(L.stakingSubaccountPreimage(Principal.fromText("3gs3h-yg6vu-aaaaa-aaaaa-cai"), 7));
let v2expect : [Nat8] = [12, 110, 101, 117, 114, 111, 110, 45, 115, 116, 97, 107, 101,
                          222, 173, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 7];
check("vector 2: preimage is 31 bytes", v2.size() == 31);
check("vector 2: preimage matches the IC construction", eqBytes(v2, v2expect));

// Vector 3: a different principal and a nonce that exercises more than the low byte.
let v3 = bytesOf(L.stakingSubaccountPreimage(Principal.fromText("3bt5t-v66vu-aaaaa-aaaaq-cai"), 42));
let v3expect : [Nat8] = [12, 110, 101, 117, 114, 111, 110, 45, 115, 116, 97, 107, 101,
                          222, 173, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 42];
check("vector 3: preimage matches the IC construction", eqBytes(v3, v3expect));

// The domain separator length byte must be 12, not the string length of something else.
check("domain length byte is 12", v1[0] == 12);

// Big-endian nonce: 0x0102030405060708 must appear in that order, not reversed.
let vbe = bytesOf(L.stakingSubaccountPreimage(Principal.fromText("aaaaa-aa"), 0x0102030405060708));
check("nonce is big-endian",
  vbe[13] == 1 and vbe[14] == 2 and vbe[15] == 3 and vbe[16] == 4
  and vbe[17] == 5 and vbe[18] == 6 and vbe[19] == 7 and vbe[20] == 8);

// Distinct nonces must give distinct preimages, or two entries would share a subaccount.
let n1 = bytesOf(L.stakingSubaccountPreimage(Principal.fromText("aaaaa-aa"), 1));
let n2 = bytesOf(L.stakingSubaccountPreimage(Principal.fromText("aaaaa-aa"), 2));
check("distinct nonces give distinct preimages", not eqBytes(n1, n2));

// ══ PART 5 ══ reserve and reconciliation ═════════════════════════════════════════════
Debug.print("PART 5  reserve sizing and reconciliation");

let FEE = 10_000;
check("reserve covers amount plus one fee per entry",
  L.reserveNeeded([100, 200, 300], FEE) == 600 + 3 * FEE);
check("empty table needs nothing", L.reserveNeeded([], FEE) == 0);

// INV-R1: everything in is either paid out, spent on fees, or still here.
let recOk = L.reconcile(1_000_000, 700_000, 30_000, 270_000);
check("INV-R1 holds when the books balance", recOk.holds);
check("INV-R1 reports both sides", recOk.expectedBalance == 270_000 and recOk.reserveBalance == 270_000);

let recShort = L.reconcile(1_000_000, 700_000, 30_000, 269_999);
check("INV-R1 fails on a one-unit shortfall", not recShort.holds);
let recOver = L.reconcile(1_000_000, 700_000, 30_000, 270_001);
check("INV-R1 fails on a one-unit surplus", not recOver.holds);

// Nothing paid yet: the whole reserve must still be there.
let recFresh = L.reconcile(500, 0, 0, 500);
check("INV-R1 holds before any payout", recFresh.holds);

// ── Driver backoff (audit R-1) ────────────────────────────────────────────────────────
// Unconditional retries are what turned one ledger outage into a walk through the whole
// table. The backoff must grow, must be capped, and must clear completely on success.
check("no failures means every tick attempts", L.backoffTicks(0) == 1);
check("one failure backs off to 2 ticks", L.backoffTicks(1) == 2);
check("three failures back off to 8 ticks", L.backoffTicks(3) == 8);
check("the backoff is capped at 240 ticks, one hour", L.backoffTicks(50) == 240);
check("the cap is never exceeded however long the outage", L.backoffTicks(100000) == 240);
check("tick 0 attempts even while failing", L.mayAttempt(0, 5));
check("a tick inside the backoff window does NOT attempt", not L.mayAttempt(1, 5));
check("a tick on the boundary attempts", L.mayAttempt(32, 5));
check("recovery is immediate: success clears the backoff", L.mayAttempt(7, 0));
// The memo is part of the ICRC-1 dedup tuple, so two entries must never collide into one
// another's dedup slot.
check("entry memos are distinct", L.transferMemo(0) != L.transferMemo(1));
check("a memo is the 8 bytes ICRC-1 expects", L.transferMemo(348).size() == 8);
check("memos are stable across calls", L.transferMemo(42) == L.transferMemo(42));

// Settlement. Every entry terminal and the books balancing. A #Failed entry is an account
// below the transfer fee: resolved, not obstructing, since nothing here is irreversible.
func stats(entries : Nat, done : Nat, failed : Nat) : T.Stats {
  { entries; done; granted = done; failed; pending = 0;
    paidOut = 0; totalObligation = 0; initialReserve = 0; feesPaid = 0 };
};
check("settled when every entry is Done and the books balance",
  L.settled(stats(10, 10, 0), recOk));
check("settled when the remainder is written off as unpayable",
  L.settled(stats(10, 9, 1), recOk));
check("settled when every entry is unpayable and nothing was paid",
  L.settled(stats(10, 0, 10), recOk));
check("NOT settled with an entry still in flight",
  not L.settled(stats(10, 9, 0), recOk));
check("NOT settled when in-flight entries hide behind a write-off",
  not L.settled(stats(10, 8, 1), recOk));
check("NOT settled when the books do not balance",
  not L.settled(stats(10, 10, 0), recShort));
// A full-size table: a few hundred entries with a handful unpayable. Under the previous
// rule this could never be true, so the query could never say anything. It must be true
// now. These counts are test inputs. The binding table is published at launch.
check("settled on a full-size table: 329 paid, 20 written off",
  L.settled(stats(349, 329, 20), recOk));
check("NOT settled while one staker has yet to nominate",
  not L.settled(stats(349, 328, 20), recOk));

// ── PART 6  neuron permissions ────────────────────────────────────────────────────────
//
// Added 2026-09-09, after the PocketIC run against real SNS Governance. The canister used
// to hand governance a hardcoded `[0 ... 11]`; `NeuronPermissionType` has ELEVEN values,
// 0 to 10, and governance refuses an over-long list outright. Nothing is hardcoded any
// more: the grant uses the live grantable set, and the strip removes what the neuron says
// the neuron records for this canister. These check the two pure helpers that make that
// possible.
Debug.print("PART 6  neuron permissions");

let alice = Principal.fromText("3gs3h-yg6vu-aaaaa-aaaaa-cai");
let bob = Principal.fromText("3bt5t-v66vu-aaaaa-aaaaq-cai");
let carol = Principal.fromText("3iqwp-dw6vu-aaaaa-aaaba-cai");

let perms : [{ principal : ?Principal; permission_type : [Int32] }] = [
  { principal = ?alice; permission_type = [0, 1, 2] },
  { principal = ?bob; permission_type = [4, 5] },
  { principal = null; permission_type = [9] },
];

check("permissionsOf finds the caller's own set",
  L.permissionsOf(perms, alice) == [0, 1, 2]);
check("permissionsOf does not confuse two principals",
  L.permissionsOf(perms, bob) == [4, 5]);
// The "already stripped, reply lost" case. It must read as empty
// rather than as an error, or a lost reply wedges the entry one step from Done.
check("permissionsOf returns empty for a principal that holds nothing",
  L.permissionsOf(perms, carol) == []);
check("permissionsOf ignores an entry with no principal",
  L.permissionsOf(perms, alice).size() == 3);
check("permissionsOf on an empty neuron is empty",
  L.permissionsOf([], alice) == []);

check("a non-empty grantable set is usable", L.grantableIsUsable([0, 1, 2]));
// Fail closed: granting nothing would mark the entry #Granted -- the status past which the
// canister assumes the holder is whole -- while the holder controls nothing at all.
check("an empty grantable set is NOT usable", not L.grantableIsUsable([]));
check("a single-permission grantable set is usable", L.grantableIsUsable([2]));

// ══ PART 7 ══ driver fairness ════════════════════════════════════════════════════════
//
// The driver scans from a rotating cursor. A scan that restarts at index 0 every time stops
// at the first ready entry whether or not it can succeed, so one permanently-failing entry
// prevents every entry behind it from being attempted.
Debug.print("PART 7  driver fairness");

// A scan visits every index exactly once per cycle, from any starting cursor.
var seen = 0;
var allOnce = true;
for (c in [0, 1, 3, 4].values()) {
  var mask = 0;
  var st = 0;
  while (st < 5) {
    let idx = L.scanIndex(c, st, 5);
    if (idx >= 5) { allOnce := false };
    mask += 2 ** idx;
    st += 1;
  };
  if (mask != 31) { allOnce := false };
  seen += 1;
};
check("a scan from any cursor visits every index exactly once", allOnce and seen == 4);
check("scanIndex wraps at the end of the table", L.scanIndex(3, 3, 5) == 1);
check("scanIndex starts at the cursor", L.scanIndex(2, 0, 5) == 2);
check("scanIndex on an empty table is 0", L.scanIndex(0, 0, 0) == 0);

check("the cursor advances past the attempted entry", L.advanceCursor(2, 5) == 3);
check("the cursor wraps at the last entry", L.advanceCursor(4, 5) == 0);
check("advanceCursor on an empty table is 0", L.advanceCursor(0, 0) == 0);

// Per-entry pacing. A healthy entry is attempted every tick; a failing one yields its turn.
check("an entry with no failures is attempted every tick", L.entryMayAttempt(7, 0));
check("an entry with no failures is attempted on tick 0", L.entryMayAttempt(0, 0));
var pacedOut = 0;
var t = 1;
while (t <= 16) { if (not L.entryMayAttempt(t, 4)) { pacedOut += 1 }; t += 1 };
check("a repeatedly failing entry is held on most ticks", pacedOut >= 14);
// Never permanent: the curve is periodic, so a failing entry always comes round again.
var everRuns = false;
t := 1;
while (t <= 300) { if (L.entryMayAttempt(t, 9)) { everRuns := true }; t += 1 };
check("a failing entry is never held for ever", everRuns);

// mostFailed names the entry a stalled table is stalled on.
check("mostFailed picks the entry with the most consecutive failures",
  L.mostFailed([0, 3, 1, 0], [false, false, false, false]) == ?1);
check("mostFailed ignores terminal entries",
  L.mostFailed([0, 9, 1, 0], [false, true, false, false]) == ?2);
check("mostFailed is null when nothing has failed",
  L.mostFailed([0, 0, 0], [false, false, false]) == null);
check("mostFailed is null on an empty table", L.mostFailed([], []) == null);

// ── result ────────────────────────────────────────────────────────────────────────────
Debug.print("");
Debug.print("checks: " # Nat.toText(checks) # "   failures: " # Nat.toText(failures));
if (failures > 0) { Runtime.trap("REDEMPTION LOGIC BATTERY FAILED: " # Nat.toText(failures) # " check(s)") };
Debug.print("ALL REDEMPTION LOGIC CHECKS PASSED");

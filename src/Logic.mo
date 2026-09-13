/// Logic.mo: the PURE decision core of the redemption canister.
///
/// Every function here is referentially transparent (no awaits, no state, no I/O) so the
/// whole battery runs under `mops test --mode interpreter` with no replica. Redemption.mo
/// calls these for the arithmetic and the gating; the tests drive the same functions.
/// Same split as dvp-core's DvpLogic.mo, and for the same reason: the error-prone parts
/// belong somewhere they can be exhaustively checked.

import T "Types";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Int "mo:core/Int";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import Principal "mo:core/Principal";

module {

  /// 26 weeks = 182 days. NEVER computed from "months": 6 * 30 days is 180 days, two days
  /// under the voting floor, and every neuron issued at that value would exist, be owned
  /// correctly, and be silently unable to vote. Verified against sns_init.yaml
  /// `minimum_dissolve_delay: 26 weeks`.
  public let DISSOLVE_FLOOR_SECONDS : Nat64 = 15_724_800;

  /// SNS `minimum_creation_stake` for MENES: 10 tokens at 8 decimals.
  /// Verified equal to menes_sale's own MIN_STAKE_E8S (main.mo:185).
  public let MIN_NEURON_STAKE_E8S : Nat = 1_000_000_000;

  // ── Dissolve delay ──────────────────────────────────────────────────────────────────
  //
  // A staker keeps the remainder of the lock they chose; everybody else, and anyone whose
  // remainder is short, gets the floor. Computed once at snapshot time and stored, so the
  // outcome cannot drift with when the payout actually runs.

  /// `lockUntilNs` and `snapshotNs` are IC nanosecond timestamps. A lock already expired
  /// at snapshot time yields the floor, never a negative or wrapped value.
  public func dissolveDelayFor(lockUntilNs : Int, snapshotNs : Int, floor : Nat64) : Nat64 {
    if (lockUntilNs <= snapshotNs) return floor;
    let remainingSecs : Nat64 = Nat64.fromNat(Int.abs((lockUntilNs - snapshotNs) / 1_000_000_000));
    if (remainingSecs < floor) floor else remainingSecs;
  };

  /// A plain wallet holder always takes the floor.
  public func walletDelay(floor : Nat64) : Nat64 { floor };

  // ── Minimums, which differ by payout kind ───────────────────────────────────────────
  //
  // A NEURON cannot be created under the 10 MENES floor, so a neuron entry under it is
  // rounded UP. This never fires in practice: menes_sale enforces the same 10 MENES floor
  // on every stake (main.mo:185), so every staker clears it by construction. Kept as the
  // guard that stops a future change to either floor from stranding a claimant.
  public func payoutAmount(raw : Nat, minStake : Nat) : Nat {
    if (raw < minStake) minStake else raw;
  };

  // A LIQUID payout has no such floor. Its only limit is the ledger's own transfer fee:
  // an amount at or below the fee cannot be sent at all, at any price. A draft snapshot
  // showed a double-digit number of wallet accounts at or under the 0.0001 MENES fee,
  // holding well under a hundredth of a token in total. Such entries are unpayable and are
  // marked #Failed with the reason recorded, rather than attempted. The binding counts come
  // from the table published at launch, not from this comment.
  public func liquidPayable(amount : Nat, fee : Nat) : Bool { amount > fee };

  /// What a #Liquid holder actually receives. The ledger takes the fee from the sender,
  /// so the full amount arrives; the reserve bears the fee.
  public func liquidDelivered(amount : Nat) : Nat { amount };

  /// What the round-up costs across a table. Pure, so the number in the announcement can
  /// be derived rather than asserted.
  public func roundUpCost(raws : [Nat], minStake : Nat) : Nat {
    var cost : Nat = 0;
    for (r in raws.values()) { if (r < minStake) { cost += minStake - r } };
    cost;
  };

  // ── Reserve sizing ──────────────────────────────────────────────────────────────────
  //
  // One outbound transfer per entry, so one fee per entry. The canister has no mint
  // authority, so being short here means entries strand at #Funded, not that money is lost.
  public func reserveNeeded(amounts : [Nat], fee : Nat) : Nat {
    var total : Nat = 0;
    for (a in amounts.values()) { total += a + fee };
    total;
  };

  // ── Lifecycle gating (INV-R2: forward only) ─────────────────────────────────────────

  public func rank(s : T.Status) : Nat {
    switch (s) {
      case (#Pending) 0;
      case (#Funded) 1;
      case (#Claimed) 2;
      case (#Delayed) 3;
      case (#Granted) 4;
      case (#Done) 5;
      case (#Failed(_)) 6; // terminal, off the main line
    };
  };

  public func isTerminal(s : T.Status) : Bool {
    switch (s) { case (#Done) true; case (#Failed(_)) true; case (_) false };
  };

  /// The holder owns the neuron outright from #Granted onward. Nothing after this point
  /// can take it away, which is why the grant is done before the strip.
  public func holderIsWhole(s : T.Status) : Bool {
    switch (s) { case (#Granted) true; case (#Done) true; case (_) false };
  };

  /// A status may only be replaced by one that ranks strictly higher, or by #Failed.
  /// This is the single check that enforces INV-R2.
  public func canAdvance(from : T.Status, to : T.Status) : Bool {
    switch (to) {
      case (#Failed(_)) { not isTerminal(from) };
      case (_) { not isTerminal(from) and rank(to) > rank(from) };
    };
  };

 /// The next status on the happy path for a NEURON entry.
  public func successor(s : T.Status) : ?T.Status {
    switch (s) {
      case (#Pending) ?#Funded;
      case (#Funded) ?#Claimed;
      case (#Claimed) ?#Delayed;
      case (#Delayed) ?#Granted;
      case (#Granted) ?#Done;
      case (#Done) null;
      case (#Failed(_)) null;
    };
  };

  /// The next status for a LIQUID entry: one transfer and it is finished. Keeping this
  /// separate from `successor` is what stops a liquid entry from ever entering the neuron
  /// path, where it would be sent to a governance subaccount and stranded.
  public func successorLiquid(s : T.Status) : ?T.Status {
    switch (s) { case (#Pending) ?#Done; case (_) null };
  };

  /// A per-entry memo on every outbound transfer. Part of the ICRC-1 deduplication tuple, so
  /// two different entries can never collide into one another's dedup slot, and it makes the
  /// ledger's own history readable per entry.
  public func transferMemo(index : Nat) : Blob {
    Blob.fromArray(VarArray.toArray(
      VarArray.tabulate<Nat8>(8, func(k : Nat) : Nat8 {
        Nat8.fromNat((index / (256 ** k)) % 256)
      })));
  };

  // ── Driver backoff (audit R-1) ──────────────────────────────────────────────────────
  //
  // The timer used to attempt one entry every tick unconditionally. With a ledger that
  // rejects, that walked the whole table destroying an entry every 15 seconds. Rolling the
  // mark back stops the destruction; this stops the pointless hammering, and stops a long
  // outage from burning cycles at one inter-canister call per tick per entry.
  //
  // Exponential, capped. Never permanent: the backoff shrinks to nothing the moment one
  // attempt succeeds, so recovery needs no operator and no new authority.

  /// Ticks to skip before the next attempt, given consecutive failures. 0 failures means
  /// every tick; the cap is 240 ticks, one hour at the 15-second period.
  public func backoffTicks(consecutiveFailures : Nat) : Nat {
    if (consecutiveFailures == 0) return 1;
    var b = 1;
    var n = consecutiveFailures;
    while (n > 0 and b < 240) { b *= 2; n -= 1 };
    if (b > 240) 240 else b;
  };

  /// Whether this tick may attempt anything.
  public func mayAttempt(tick : Nat, consecutiveFailures : Nat) : Bool {
    tick % backoffTicks(consecutiveFailures) == 0;
  };

  // ── Driver fairness ─────────────────────────────────────────────────────────────────
  //
  // The driver scans from a rotating cursor rather than from index 0. A scan that always
  // restarts at 0 stops at the first entry that is ready, whether or not that entry can
  // succeed, so one permanently-failing entry prevents every entry behind it from being
  // attempted at all. The cursor advances past whatever was attempted, so each ready entry
  // takes its turn.

  /// The index to examine at position `step` of a scan that begins at `cursor`. Visits every
  /// index exactly once for `step` in 0..size-1.
  public func scanIndex(cursor : Nat, step : Nat, size : Nat) : Nat {
    if (size == 0) return 0;
    (cursor + step) % size;
  };

  /// Where the cursor moves after entry `i` has been attempted.
  public func advanceCursor(i : Nat, size : Nat) : Nat {
    if (size == 0) return 0;
    (i + 1) % size;
  };

  /// Whether a repeatedly failing entry takes its turn on this tick. Same curve as the
  /// driver-wide backoff, applied per entry, so a failing entry costs the table one attempt
  /// per cycle instead of every attempt. Never permanent: one success resets the count.
  public func entryMayAttempt(tick : Nat, entryFailures : Nat) : Bool {
    tick % backoffTicks(entryFailures) == 0;
  };

  /// The entry a stalled table is stalled on: the non-terminal entry with the most
  /// consecutive failures. Reported by `settlement()` so a table that is not advancing says
  /// why, rather than only showing entries pending.
  public func mostFailed(failures : [Nat], terminal : [Bool]) : ?Nat {
    var i = 0;
    var best : ?Nat = null;
    var bestFailures = 0;
    while (i < failures.size() and i < terminal.size()) {
      if (not terminal[i] and failures[i] > bestFailures) {
        best := ?i;
        bestFailures := failures[i];
      };
      i += 1;
    };
    best;
  };

  /// Which chain an entry walks, decided by its payout kind and nothing else.
  public func nextFor(payout : T.Payout, s : T.Status) : ?T.Status {
    switch (payout) {
      case (#Liquid) successorLiquid(s);
      case (#Neuron(_)) successor(s);
    };
  };

  /// What a neuron entry is actually waiting for.
  ///
  /// A neuron needs a controller principal, and the principal on the snapshot is the one
  /// the holder used on the Menese app. Internet Identity derives a different principal per
  /// origin, so that one cannot control a neuron reached from anywhere else. The entry
  /// therefore waits until its owner nominates a destination.
  ///
  /// There is deliberately NO liquid fallback for a staker. A staker chose a lock, and a
  /// liquid payout is not the thing they chose.
  /// A staker who never nominates simply waits; their tokens stay in the reserve and the
  /// entry stays claimable indefinitely. Waiting is not failing, and nothing is lost.
  public type Ready = { #Ready : T.Payout; #AwaitingDestination };

  public func resolvePayout(payout : T.Payout, destination : ?Principal) : Ready {
    switch (payout) {
      case (#Liquid) #Ready(#Liquid);
      case (#Neuron(n)) {
        switch (destination) { case (?_) #Ready(#Neuron(n)); case null #AwaitingDestination };
      };
    };
  };

  /// Who a payout may be sent to. The owner may nominate a destination for a NEURON, and
  /// nobody else may nominate anything. A liquid payout always goes to the owner, so there
  /// is no destination to redirect and nothing to get wrong.
  public func recipient(owner : Principal, destination : ?Principal, kind : T.Payout) : Principal {
    switch (kind, destination) {
      case (#Neuron(_), ?d) d;
      case (_, _) owner;
    };
  };

  // ── Neuron permissions ──────────────────────────────────────────────────────────────
  //
  // The permission ids are defined by governance and are never inferred here. `ALL_PERMISSIONS`
  // was formerly a hardcoded `[0 ... 11]`; the enum has eleven values, and governance rejects
  // any list longer than its own enum before it even checks the grantable subset. Every
  // neuron entry wedged at the grant step as a result, with this canister left as the
  // neuron's sole controller. Both functions below exist so no list is ever invented:
  // the grant uses what governance reports as grantable, and the strip uses what the neuron
  // itself records for this canister.

  /// The permissions `who` holds on a neuron, as governance reports them. Empty if `who`
  /// appears nowhere in the list, which is the "already stripped" case.
  public func permissionsOf(
    perms : [{ principal : ?Principal; permission_type : [Int32] }],
    who : Principal,
  ) : [Int32] {
    var found : [Int32] = [];
    for (p in perms.values()) {
      switch (p.principal) {
        case (?owner) { if (Principal.equal(owner, who)) { found := p.permission_type } };
        case null {};
      };
    };
    found;
  };

  /// Is this a permission set worth granting? An empty set would produce a neuron nobody
  /// can control, which is worse than not granting at all, so the caller must refuse it.
  public func grantableIsUsable(permissions : [Int32]) : Bool { permissions.size() > 0 };

  // ── Neuron staking subaccount ───────────────────────────────────────────────────────
  //
  // The preimage of the SNS staking subaccount, byte-for-byte as the IC computes it in
  // rs/nervous_system/common/src/ledger.rs:
  //
  //     sha256( [domain_len] ++ b"neuron-stake" ++ controller.as_slice() ++ nonce_be )
  //
  // Kept pure and separate from the hash so the byte layout itself is unit-testable; the
  // caller applies SHA-256. Getting this wrong sends tokens to a subaccount no neuron will
  // ever be claimed from, so it is pinned by a test vector rather than trusted.
  public func stakingSubaccountPreimage(controller : Principal, nonce : Nat64) : Blob {
    let domain : [Nat8] = [0x6e, 0x65, 0x75, 0x72, 0x6f, 0x6e, 0x2d, 0x73, 0x74, 0x61, 0x6b, 0x65]; // "neuron-stake"
    let pbytes = Blob.toArray(Principal.toBlob(controller));
    let total = 1 + domain.size() + pbytes.size() + 8;
    let out = VarArray.repeat<Nat8>(0, total);
    out[0] := Nat8.fromNat(domain.size()); // 12
    var i = 0;
    while (i < domain.size()) { out[1 + i] := domain[i]; i += 1 };
    var j = 0;
    while (j < pbytes.size()) { out[1 + domain.size() + j] := pbytes[j]; j += 1 };
    // nonce, big-endian, 8 bytes
    let base = 1 + domain.size() + pbytes.size();
    var k : Nat = 0;
    while (k < 8) {
      let shift : Nat64 = Nat64.fromNat((7 - k) * 8);
      out[base + k] := Nat8.fromNat(Nat64.toNat((nonce >> shift) & 0xFF));
      k += 1;
    };
    Blob.fromArray(Array.tabulate<Nat8>(total, func(x : Nat) : Nat8 { out[x] }));
  };

  // ── Reconciliation (INV-R1) ─────────────────────────────────────────────────────────
  //
  // Everything that went in is either paid out, spent on fees, or still here. Returns both
  // sides so a caller can check the arithmetic instead of trusting a boolean.
  public func reconcile(initialReserve : Nat, paidOut : Nat, feesPaid : Nat, reserveBalance : Nat) : T.Reconciliation {
    let spent = paidOut + feesPaid;
    let expected : Nat = if (spent > initialReserve) 0 else initialReserve - spent;
    {
      initialReserve;
      paidOut;
      feesPaid;
      reserveBalance;
      expectedBalance = expected;
      holds = (expected == reserveBalance);
    };
  };

  /// Settlement: every entry has reached a terminal status and the books balance.
  ///
  /// A #Failed entry counts as resolved, not as an obstruction. It is an account holding
  /// less than the transfer fee, so it can never be paid, and the canister stays under DAO
  /// control for life, those tokens are recoverable by upgrade and are not locked by
  /// anything. Reporting them as an unresolved failure would mean this never returns true
  /// on any real table, which is a query that always says no and therefore says nothing.
  /// The count is surfaced separately so a write-off is visible rather than absorbed.
  public func settled(stats : T.Stats, rec : T.Reconciliation) : Bool {
    stats.done + stats.failed == stats.entries and rec.holds;
  };
}

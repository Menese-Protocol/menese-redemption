/// Types.mo: the redemption canister's data model.
///
/// One entry per eligible holder, fixed at initialisation and never mutated afterwards
/// except for its `status`, which only ever moves forward. See DESIGN-redemption-canister-v2.md.

module {

  /// How an entry is paid. Holders who were liquid stay liquid, because they never agreed
  /// to lock anything; stakers continue the lock they chose, as a neuron.
  public type Payout = {
    /// A plain transfer. No lock, no vote, no minimum beyond the ledger fee.
    #Liquid;
    /// A neuron under the holder's sole control. Dissolve delay in SECONDS, already
    /// floored at the voting minimum when the table was built.
    #Neuron : { delaySeconds : Nat64 };
  };

  /// A holder's entitlement, frozen at the cut-off block. The cut-off is chosen and
  /// published when the SNS launches. Immutable once installed.
  public type Entry = {
    /// The holder. For a neuron, becomes its controller; never re-pointed.
    owner : Principal;
    /// Payout in e8s of the new token.
    amount : Nat;
    payout : Payout;
    /// Provenance, carried so the published table explains itself. Not used in logic.
    source : Source;
  };

  public type Source = {
    /// Held on the old ledger at the snapshot block.
    #Wallet;
    /// An active position in menes_sale; carries the stake id it came from.
    #Stake : Nat;
  };

  /// Where a payout has got to. Advances only; never regresses (INV-R2).
  ///
  ///   Pending -> Funded -> Claimed -> Delayed -> Granted -> Done
  ///
  /// `Granted` is the safety line: at and beyond it the holder controls the neuron
  /// outright and nothing the canister does or fails to do can take it away.
  /// A #Liquid entry uses only Pending -> Done: one transfer, nothing to configure.
  /// A #Neuron entry walks the whole chain.
  public type Status = {
    #Pending;   // nothing sent
    #Funded;    // tokens are in the neuron's staking subaccount
    #Claimed;   // neuron exists, dissolve delay still 0
    #Delayed;   // dissolve delay set
    #Granted;   // holder holds every permission  <-- holder is whole from here
    #Done;      // canister's own permissions removed
    #Failed : Text; // permanently unpayable, and resolved as such: counted as written off
                    // by `settled`, with the reason kept so it is visible, never silent.
                    // The tokens stay in the canister, recoverable by DAO upgrade.
  };

  /// Runtime state of one entry. The entry itself is immutable; only this moves.
  public type Progress = {
    status : Status;
    /// Where a neuron should be created, nominated by the entry's OWN owner and by nobody
    /// else. Needed because Internet Identity gives a different principal per origin: the
    /// principal that staked on the Menese app cannot control a neuron reached from the
    /// NNS dapp. Must be a PRINCIPAL; an account id cannot control a neuron.
    destination : ?Principal;
    /// Set once the neuron id is known, so retries never re-derive it.
    neuronId : ?Blob;
    /// Last error seen, for operators. Never used to make a decision.
    lastError : ?Text;
    attempts : Nat;
    /// Consecutive failed attempts on THIS entry, reset to zero by any success. Drives the
    /// per-entry backoff, and identifies the entry a stalled table is stalled on. It never
    /// makes an entry terminal: a failing entry is not a written-off entry.
    failures : Nat;
    /// `created_at_time` of this entry's outbound transfer, fixed on the FIRST attempt and
    /// reused on every retry. This is what makes a retry safe: an ICRC-1 ledger deduplicates
    /// on the full argument tuple, so a repeat of an attempt that already landed comes back
    /// `#Duplicate` instead of paying twice. Without it a rollback-and-retry is a
    /// double-spend, which is why the canister previously could not retry at all.
    txTime : ?Nat64;
  };

  /// Reported by `stats()`, and the substrate for INV-R1.
  public type Stats = {
    entries : Nat;
    done : Nat;
    granted : Nat;
    failed : Nat;
    pending : Nat;
    /// Sum of amounts for entries at #Done.
    paidOut : Nat;
    /// Sum of amounts for every entry in the table.
    totalObligation : Nat;
    initialReserve : Nat;
    feesPaid : Nat;
  };

  /// What INV-R1 compares. Both operands are returned, so the result is independently
  /// checkable rather than asserted.
  public type Reconciliation = {
    initialReserve : Nat;
    paidOut : Nat;
    feesPaid : Nat;
    /// Live ledger balance of this canister.
    reserveBalance : Nat;
    /// initialReserve - paidOut - feesPaid
    expectedBalance : Nat;
    holds : Bool;
  };
}

/// Types.mo: the holder canister's data model.
///
/// The canister holds the MENES holders' share of MPV as its own genesis neurons, takes the
/// holder snapshot itself when the swap commits, and delivers each holder's share out of
/// those neurons. See docs/DESIGN.md.

module {

  /// One row of the holder table. Built once, on chain, at the swap's close, and never
  /// changed afterwards.
  ///
  /// Every row is a basket of n neurons, n = min(9, floor(gross / (minimum stake + fee))):
  ///   n = 9:    one part from each genesis neuron k = 0..8 (dissolve delays 0 .. 1,456 days);
  ///   n = 1..8: one part from each genesis neuron k = 1..n (182 .. n x 182 days), so every
  ///             neuron of a small basket can vote.
  /// Holders whose share stays below one minimum neuron are not rows: they are listed in
  /// the dropped list, and their share is spread over the rows by the table rule.
  public type Entry = {
    /// The holder at the snapshot. Decides WHO is entitled, and is the only principal that
    /// may nominate where the entry's neurons go.
    owner : Principal;
    /// MENES held (every subaccount folded into the owner) and staked in the sale canister
    /// at the cut, after the exclusions. In e8s of MENES.
    held : Nat;
    staked : Nat;
    /// The pro rata share of the pool among the rows, in e8s of MPV, before any fee.
    gross : Nat;
    /// The genesis neuron of the first part: 0 for a basket of nine, 1 otherwise.
    firstRung : Nat;
    /// The amount taken from genesis neuron firstRung + j, for j = 0 .. n-1. The neuron
    /// split off holds that amount less one fee; the last basket at a genesis neuron
    /// receives that genesis neuron itself, holding exactly that amount.
    neurons : [Nat];
  };

  /// A holder left out of the table because their share, even after the shares of every
  /// other holder below one minimum neuron were spread, stays below one minimum neuron.
  /// Published with the table, in principal-text order.
  public type Dropped = {
    owner : Principal;
    held : Nat;
    staked : Nat;
  };

  /// Where an entry has got to. Advances only (INV-R2).
  ///
  ///   per rung k, firstRung .. firstRung + n - 1:
  ///     Pending -> Split -> Granted -> (k+1, Pending) ... -> Done after the last rung
  ///
  /// `Granted` is the safety line for each neuron: from there the holder controls it
  /// outright and nothing this canister does or fails to do can take it away.
  public type Status = {
    #Pending;
    /// Neuron k exists for this entry (split off, or genesis neuron k handed over), still
    /// controlled by this canister alone.
    #Split;
    /// The destination holds every grantable permission on neuron k.
    #Granted;
    #Done;
  };

  public type Progress = {
    status : Status;
    /// Where the basket's neurons go, nominated by the entry's OWN owner. Internet Identity
    /// gives a different principal per origin, so the principal used in the Menese app
    /// cannot control a neuron reached from the NNS dapp.
    destination : ?Principal;
    /// The genesis neuron (rung) in flight. Rungs below it are delivered and stripped.
    neuron : Nat;
    /// The in-flight neuron's id, once it exists.
    neuronId : ?Blob;
    /// True when the in-flight neuron is genesis neuron k itself (the last basket at k).
    takesParent : Bool;
    lastError : ?Text;
    attempts : Nat;
    /// Consecutive failed attempts on this entry; reset by any success. Paces the entry.
    failures : Nat;
  };

  /// The canister's own lifecycle. Advances only.
  public type Phase = {
    /// Waiting for SNS root to be its sole controller (the swap has committed).
    #Unbound;
    /// Bound; waiting for the swap's lifecycle to say Committed, and for the cut to settle.
    #AwaitClose;
    /// Taking the snapshot, one step per tick.
    #Snapshot;
    /// The table is built and published; delivering.
    #Delivering;
    /// The swap was aborted: there is nothing to deliver, and nothing is done.
    #Aborted;
    /// A snapshot check failed. Nobody is paid; only an SNS upgrade can change this.
    #Halted : Text;
  };

  public type Binding = {
    root : Principal;
    governance : Principal;
    ledger : Principal;
    swap : Principal;
    boundAt : Int;
  };

  /// What the snapshot found, published with the table so anyone can check it.
  public type SnapshotReport = {
    /// The swap's close, from its own lifecycle (seconds).
    closeSeconds : Nat64;
    /// MENES ledger blocks folded: every block whose timestamp is at or before the close.
    cut : Nat;
    /// Timestamp of the last folded block (ns).
    lastFoldedTimestamp : Nat64;
    /// The ledger's length when it was read to the tip, and the supply rebuilt to there.
    tip : Nat;
    supplyRebuilt : Nat;
    supplyReported : Nat;
    /// Stakes read, existing at the close, and active at the close.
    stakeRecords : Nat;
    stakesAtClose : Nat;
    activeStakeTotal : Nat;
    saleBalanceAtCut : Nat;
    /// The nine genesis stakes the pool is made of.
    genesis : [Nat];
    fee : Nat;
    minimumStake : Nat;
    /// Rows of the table: baskets of nine, smaller baskets, and the neurons they add up to.
    entries : Nat;
    fullBaskets : Nat;
    smallBaskets : Nat;
    neurons : Nat;
    /// Holders left out (below one minimum neuron), their MENES weight, and the rounds the
    /// pro rata redistribution took to settle.
    dropped : Nat;
    droppedWeight : Nat;
    dropRounds : Nat;
    /// Baskets of nine whose part at some genesis neuron fell below one minimum neuron
    /// and were delivered at rungs 1..8 instead.
    movedToEight : Nat;
    /// SHA-256 of the canonical table (Logic.tableBytes), identical to build-table's.
    tableHash : Blob;
    /// Every check, in the order it ran.
    checks : [Text];
  };

  /// One neuron of an entry's basket, derived from the table and progress.
  public type BasketNeuron = {
    /// The genesis neuron it comes from, which fixes its dissolve delay.
    rung : Nat;
    /// The neuron's id: for a split-off neuron the staking subaccount of (this canister,
    /// memo), for the last basket at k the id of genesis neuron k. Known once the split is
    /// sent (or the genesis neuron is assigned), null before.
    neuronId : ?Blob;
    /// The memo, once the neuron is delivered: k for genesis neuron k, otherwise the
    /// canister's secret memo for this part (see Logic.splitMemo).
    memo : ?Nat64;
    /// True if this part is genesis neuron k itself, handed over whole.
    genesisNeuron : Bool;
    /// What the holder ends up with: the amount less the split fee, or the whole amount
    /// for genesis neuron k itself.
    stake : Nat;
    dissolveDelaySeconds : Nat64;
    delivered : Bool;
  };

  /// A neuron found at the id the canister was about to split a part to, before it sent
  /// that split. The canister never made it: the part moves to the next memo, and this
  /// neuron stays outside the books, untouched.
  public type Foreign = {
    entry : Nat;
    rung : Nat;
    neuronId : Blob;
    /// Its stake as governance reported it when found.
    stake : Nat;
  };

  public type Stats = {
    phase : Phase;
    entries : Nat;
    done : Nat;
    pending : Nat;
    fullBaskets : Nat;
    smallBaskets : Nat;
    dropped : Nat;
    neuronsDelivered : Nat;
    neuronsTotal : Nat;
    /// Genesis neurons handed over whole (the last basket at each k).
    parentsHandedOver : Nat;
    /// What each genesis neuron has given out so far: split amounts, counted when sent,
    /// released if they provably did not happen.
    takenFrom : [Nat];
    splits : Nat;
    /// What the holders hold: split-off stakes and handed-over genesis neurons.
    deliveredStake : Nat;
    feesPaid : Nat;
    /// Neurons found at a part's id before its split (see Foreign).
    foreignNeurons : Nat;
  };

  /// The books, per genesis neuron (Q6). For each neuron still held: the ledger balance of
  /// its staking subaccount against what the table still owes from it.
  public type ParentBooks = {
    index : Nat;
    expected : Nat;
    balance : Nat;
    handedOver : Bool;
  };

  public type Reconciliation = {
    parents : [ParentBooks];
    /// Every neuron still held has at least what is owed from it.
    holds : Bool;
    /// Anything above that (a donation to a staking subaccount), reported, never spent on
    /// purpose.
    surplus : Nat;
    /// pool = what has left the genesis neurons by the statuses + what the neurons still
    /// held owe. Exact.
    poolAccounted : Bool;
  };

  public type Settlement = {
    settled : Bool;
    dropped : Nat;
    neuronsDelivered : Nat;
    neuronsTotal : Nat;
    reason : Text;
  };

  /// A stake record of the MENES sale canister, exactly as its live interface returns it.
  public type LockPeriod = { #Months2; #Months4; #Months12; #Months18 };
  public type StakeInfo = {
    id : Nat;
    owner : Principal;
    amount : Nat;
    active : Bool;
    stakedAt : Int;
    lockUntil : Int;
    lockPeriod : LockPeriod;
    pendingRewards : Nat;
    weightedAmount : Nat;
  };
}

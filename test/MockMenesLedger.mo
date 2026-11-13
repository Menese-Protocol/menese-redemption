/// MockMenesLedger.mo: a test MENES ledger with the legacy `get_transactions` surface of
/// DFINITY's ic-icrc1-ledger (git cacf86a2): recent blocks in the reply, older ones behind
/// an archive callback. Blocks are loaded by the test in compact form. Faults: a reported
/// supply that differs from the blocks, a block the archive does not return, and blocks
/// appended later (after the cut).
import List "mo:core/List";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";

persistent actor MockMenesLedger {

  type Account = { owner : Principal; subaccount : ?Blob };
  type Mint = { to : Account; amount : Nat; memo : ?Blob; created_at_time : ?Nat64 };
  type Burn = { from : Account; amount : Nat; memo : ?Blob; created_at_time : ?Nat64; spender : ?Account };
  type Transfer = { from : Account; to : Account; amount : Nat; fee : ?Nat; memo : ?Blob; created_at_time : ?Nat64; spender : ?Account };
  type Approve = { from : Account; spender : Account; amount : Nat; fee : ?Nat; expected_allowance : ?Nat; expires_at : ?Nat64; memo : ?Blob; created_at_time : ?Nat64 };
  type Transaction = { kind : Text; mint : ?Mint; burn : ?Burn; transfer : ?Transfer; approve : ?Approve; timestamp : Nat64 };
  type Request = { start : Nat; length : Nat };
  type Range = { transactions : [Transaction] };
  type ArchivedRange = { start : Nat; length : Nat; callback : shared query Request -> async Range };

  /// Compact block: kind 0 mint, 1 transfer, 2 burn, 3 approve. `from` is the sender (or the
  /// approver), `to` the receiver (or the spender). Subaccounts are kept so the fold into
  /// the owner is exercised.
  public type Compact = {
    kind : Nat8; from : Principal; fromSub : ?Blob; to : Principal; toSub : ?Blob;
    amount : Nat; fee : Nat; ts : Nat64; viaSpender : Bool;
  };

  let blocks = List.empty<Transaction>();
  /// Blocks below this index are served through the archive callback.
  var firstIndex : Nat = 0;
  var supplyDelta : Int = 0;
  var missing : ?Nat = null;
  var supply : Int = 0;
  /// While set, every read traps (a rejected call, as from a ledger being upgraded).
  var rejecting : Bool = false;

  func expand(c : Compact) : Transaction {
    let from = { owner = c.from; subaccount = c.fromSub };
    let to = { owner = c.to; subaccount = c.toSub };
    switch (c.kind) {
      case 0 { { kind = "mint"; mint = ?{ to; amount = c.amount; memo = null; created_at_time = null }; burn = null; transfer = null; approve = null; timestamp = c.ts } };
      case 2 { { kind = "burn"; mint = null; burn = ?{ from; amount = c.amount; memo = null; created_at_time = null; spender = null }; transfer = null; approve = null; timestamp = c.ts } };
      case 3 { { kind = "approve"; mint = null; burn = null; transfer = null; timestamp = c.ts;
                 approve = ?{ from; spender = to; amount = c.amount; fee = ?c.fee; expected_allowance = null; expires_at = null; memo = null; created_at_time = null } } };
      case _ { { kind = "transfer"; mint = null; burn = null; approve = null; timestamp = c.ts;
                 transfer = ?{ from; to; amount = c.amount; fee = ?c.fee; memo = null; created_at_time = ?c.ts;
                               spender = if (c.viaSpender) ?{ owner = c.to; subaccount = null } else null } } };
    };
  };

  func supplyEffect(c : Compact) : Int {
    switch (c.kind) { case 0 c.amount; case 2 -c.amount; case _ -c.fee };
  };

  public func load(cs : [Compact]) : async Nat {
    for (c in cs.values()) { List.add(blocks, expand(c)); supply += supplyEffect(c) };
    List.size(blocks);
  };
  public func setArchived(n : Nat) : async () { firstIndex := n };
  public func setSupplyDelta(d : Int) : async () { supplyDelta := d };
  public func setMissing(m : ?Nat) : async () { missing := m };
  public func setRejecting(r : Bool) : async () { rejecting := r };

  func slice(start : Nat, length : Nat) : [Transaction] {
    let n = List.size(blocks);
    if (start >= n) return [];
    let end = Nat.min(n, start + length);
    let out = List.empty<Transaction>();
    var i = start;
    while (i < end) {
      if (missing == ?i) return List.toArray(out);
      List.add(out, List.at(blocks, i));
      i += 1;
    };
    List.toArray(out);
  };

  public query func archive_get_transactions(r : Request) : async Range {
    if (rejecting) Runtime.trap("injected reject on the archive");
    let end = Nat.min(firstIndex, r.start + r.length);
    if (r.start >= end) return { transactions = [] };
    { transactions = slice(r.start, end - r.start) };
  };

  public query func get_transactions(r : Request) : async {
    log_length : Nat; first_index : Nat; transactions : [Transaction]; archived_transactions : [ArchivedRange];
  } {
    if (rejecting) Runtime.trap("injected reject on get_transactions");
    let n = List.size(blocks);
    let archived : [ArchivedRange] = if (r.start < firstIndex and r.length > 0) {
      [{ start = r.start; length = Nat.min(firstIndex, r.start + r.length) - r.start; callback = archive_get_transactions }];
    } else [];
    let from = Nat.max(r.start, firstIndex);
    let to = Nat.min(n, r.start + r.length);
    let txs = if (from < to) slice(from, to - from) else [];
    { log_length = n; first_index = from; transactions = txs; archived_transactions = archived };
  };

  public query func icrc1_total_supply() : async Nat {
    if (rejecting) Runtime.trap("injected reject on icrc1_total_supply");
    Int.abs(supply + supplyDelta);
  };
  public query func length() : async Nat { List.size(blocks) };
}

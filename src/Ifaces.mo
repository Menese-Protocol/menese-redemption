/// Ifaces.mo: every other canister this canister calls, transcribed from their live
/// interfaces. Field names and variant tags must match exactly or a call decodes to garbage.

import T "Types";

module {

  // ── The MENES ledger (DFINITY ic-icrc1-ledger, git cacf86a2) ───────────────────────
  // Its legacy `get_transactions` returns blocks still on the ledger and, for older ones,
  // callbacks into the archive canisters that hold them.

  public type Account = { owner : Principal; subaccount : ?Blob };

  public type Mint = { to : Account; amount : Nat; memo : ?Blob; created_at_time : ?Nat64 };
  public type Burn = { from : Account; amount : Nat; memo : ?Blob; created_at_time : ?Nat64; spender : ?Account };
  public type Transfer = {
    from : Account; to : Account; amount : Nat; fee : ?Nat;
    memo : ?Blob; created_at_time : ?Nat64; spender : ?Account;
  };
  public type Approve = {
    from : Account; spender : Account; amount : Nat; fee : ?Nat;
    expected_allowance : ?Nat; expires_at : ?Nat64; memo : ?Blob; created_at_time : ?Nat64;
  };
  public type Transaction = {
    kind : Text;
    mint : ?Mint;
    burn : ?Burn;
    transfer : ?Transfer;
    approve : ?Approve;
    timestamp : Nat64;
  };
  public type GetTransactionsRequest = { start : Nat; length : Nat };
  public type TransactionRange = { transactions : [Transaction] };
  public type ArchivedRange = {
    start : Nat;
    length : Nat;
    callback : shared query GetTransactionsRequest -> async TransactionRange;
  };
  public type GetTransactionsResponse = {
    log_length : Nat;
    first_index : Nat;
    transactions : [Transaction];
    archived_transactions : [ArchivedRange];
  };
  public type MenesLedger = actor {
    get_transactions : shared query GetTransactionsRequest -> async GetTransactionsResponse;
    icrc1_total_supply : shared query () -> async Nat;
  };

  // ── The MENES sale canister (its live interface) ──────────────────────────────────
  public type MenesSale = actor {
    getStakeInfo : shared query Nat -> async ?T.StakeInfo;
  };

  // ── The MPV ledger: only the balance of a staking subaccount is read ──────────────
  public type SnsLedger = actor {
    icrc1_balance_of : shared query Account -> async Nat;
  };

  // ── SNS swap ─────────────────────────────────────────────────────────────────────
  /// Lifecycle codes: 0 Unspecified, 1 Pending, 2 Open, 3 Committed, 4 Aborted, 5 Adopted.
  public type GetLifecycleResponse = {
    lifecycle : ?Int32;
    decentralization_sale_open_timestamp_seconds : ?Nat64;
    decentralization_swap_termination_timestamp_seconds : ?Nat64;
  };
  public type Swap = actor {
    get_lifecycle : shared query {} -> async GetLifecycleResponse;
  };

  // ── SNS root ─────────────────────────────────────────────────────────────────────
  public type ListSnsCanistersResponse = {
    root : ?Principal;
    swap : ?Principal;
    ledger : ?Principal;
    index : ?Principal;
    governance : ?Principal;
    dapps : [Principal];
    archives : [Principal];
  };
  public type SnsRoot = actor {
    list_sns_canisters : shared query {} -> async ListSnsCanistersResponse;
  };

  // ── NNS SNS-W: the SNSes the NNS has deployed ────────────────────────────────────
  public type DeployedSns = {
    root_canister_id : ?Principal;
    governance_canister_id : ?Principal;
    ledger_canister_id : ?Principal;
    swap_canister_id : ?Principal;
    index_canister_id : ?Principal;
  };
  public type SnsWasm = actor {
    list_deployed_snses : shared query {} -> async { instances : [DeployedSns] };
  };

  // ── The management canister ──────────────────────────────────────────────────────
  public type CanisterInfo = {
    total_num_changes : Nat64;
    module_hash : ?Blob;
    controllers : [Principal];
  };
  public type Management = actor {
    canister_info : shared { canister_id : Principal; num_requested_changes : ?Nat64 } -> async CanisterInfo;
    raw_rand : shared () -> async Blob;
  };
}

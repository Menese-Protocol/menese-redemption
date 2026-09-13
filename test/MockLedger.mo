/// MockLedger.mo: an ICRC-1 ledger faithful enough to test the redemption path.
///
/// Same idea as dvp-core's FlakyLedger: model the fee and the failure modes exactly, so the
/// canister under test meets the real semantics, and add a switch to inject failures on
/// demand so the error paths are exercised rather than assumed.

import Principal "mo:core/Principal";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Iter "mo:core/Iter";
import Runtime "mo:core/Runtime";

persistent actor class MockLedger(fee : Nat) {

  type Account = { owner : Principal; subaccount : ?Blob };
  type TransferArgs = {
    from_subaccount : ?Blob; to : Account; amount : Nat;
    fee : ?Nat; memo : ?Blob; created_at_time : ?Nat64;
  };
  type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };
  type TransferResult = { #Ok : Nat; #Err : TransferError };

  var balances = Map.empty<Text, Nat>();
  var blockIdx : Nat = 0;
  var failNext : Nat = 0; // fail the next N transfers, to exercise the error path
  // Trap the next N transfers. A returned #Err and a REJECT are different outcomes and the
  // canister handles only the first: a trap here surfaces at the caller's `await` as an
  // Error, and with no try/catch the caller's message traps too. This is what models the
  // ledger being stopped, mid-upgrade, or out of cycles.
  var trapNext : Nat = 0;

  var dedup = Map.empty<Text, Nat>();
  // A real ICRC-1 ledger keeps a bounded transaction window, typically 24 hours. The
  // canister's retry safety is only as good as this window, so the mock has one.
  transient let txWindowNs : Nat64 = 86_400_000_000_000;
  // Starts at zero so nothing is #TooOld by default; a test pushes it past a transfer's
  // created_at_time plus the window to exercise that arm deliberately.
  var nowNs : Nat64 = 0;

  func key(a : Account) : Text {
    Principal.toText(a.owner) # "#" # (switch (a.subaccount) { case (?s) debug_show (Blob.toArray(s)); case null "" });
  };

  /// The full ICRC-1 deduplication tuple. Anything less would let two distinct transfers
  /// collide, which would make the mock kinder than a real ledger.
  func dedupKey(from : Account, args : TransferArgs, t : Nat64) : Text {
    key(from) # "|" # key(args.to) # "|" # Nat.toText(args.amount)
      # "|" # (switch (args.fee) { case (?f) Nat.toText(f); case null "-" })
      # "|" # (switch (args.memo) { case (?m) debug_show (Blob.toArray(m)); case null "-" })
      # "|" # Nat64.toText(t);
  };
  func get(a : Account) : Nat { switch (Map.get(balances, Text.compare, key(a))) { case (?v) v; case null 0 } };
  func put(a : Account, v : Nat) { Map.add(balances, Text.compare, key(a), v) };

  public func mint(to : Account, amount : Nat) : async () { put(to, get(to) + amount) };
  public func setFailNext(n : Nat) : async () { failNext := n };
  public func setTrapNext(n : Nat) : async () { trapNext := n };

  public query func icrc1_fee() : async Nat { fee };
  public query func icrc1_balance_of(a : Account) : async Nat { get(a) };

  public shared ({ caller }) func icrc1_transfer(args : TransferArgs) : async TransferResult {
    if (trapNext > 0) { trapNext -= 1; Runtime.trap("mock ledger unavailable") };
    if (failNext > 0) { failNext -= 1; return #Err(#TemporarilyUnavailable) };
    let from : Account = { owner = caller; subaccount = args.from_subaccount };

    // ICRC-1 deduplication, modelled because the canister's retry safety depends on it. A
    // repeat of the exact same argument tuple returns #Duplicate rather than transferring
    // again. Only transfers carrying `created_at_time` participate: without it a real ledger
    // has no dedup window either, which is the defect audit R-3 named.
    switch (args.created_at_time) {
      case (?t) {
        let k = dedupKey(from, args, t);
        switch (Map.get(dedup, Text.compare, k)) {
          case (?blk) { return #Err(#Duplicate({ duplicate_of = blk })) };
          case null {};
        };
        if (t + txWindowNs < nowNs) { return #Err(#TooOld) };
      };
      case null {};
    };

    let have = get(from);
    // The sender pays amount + fee, exactly as a real ICRC-1 ledger does.
    if (have < args.amount + fee) return #Err(#InsufficientFunds({ balance = have }));
    put(from, have - args.amount - fee);
    put(args.to, get(args.to) + args.amount);
    blockIdx += 1;
    switch (args.created_at_time) {
      case (?t) { Map.add(dedup, Text.compare, dedupKey(from, args, t), blockIdx) };
      case null {};
    };
    #Ok(blockIdx);
  };

  /// Test helper: advance the ledger's notion of now, so #TooOld can be exercised without
  /// waiting out a real transaction window.
  public func advanceTime(ns : Nat64) : async () { nowNs += ns };

  /// Test helper: how many transfers actually moved value. A retry that deduplicates must
  /// not increment this.
  public query func transferCount() : async Nat { blockIdx };

  /// Test helper: total supply still accounted for, so the harness can assert conservation.
  public query func totalHeld() : async Nat {
    var t = 0;
    for (v in Map.values(balances)) { t += v };
    t;
  };
}

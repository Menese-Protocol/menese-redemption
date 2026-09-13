/// MockGov.mo, SNS governance, faithful on the parts that can lose money.
///
/// Three behaviours are modelled exactly because each one is a trap the redemption canister
/// has to survive, and a mock that got any of them wrong would let a real bug through:
///
///   1. A claimed neuron is created at dissolve delay ZERO (governance.rs:4367).
///   2. IncreaseDissolveDelay is ADDITIVE, not absolute (governance.did). A blind retry
///      therefore doubles the delay, and the canister under test must not do that.
///   3. A stake under neuron_minimum_stake_e8s DELETES the neuron and errors, AFTER the
///      tokens have already landed in the subaccount (governance.rs:~4392).
///
/// It also enforces that the claimed neuron's permissions go to the *controller* named in
/// the request, not to the caller, which is the property the whole design rests on.
///
///   4. Permission validation. The deployed canister checks the submitted list's length
///      against its own enum FIRST (governance.rs:4609) and the grantable subset SECOND
///      (governance.rs:4620). Both are modelled below, in that order, with governance's own
///      error strings. Defect F-1 is the recorded instance of what this omission allows.

import Principal "mo:core/Principal";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Array "mo:core/Array";
import List "mo:core/List";
import Sha256 "mo:sha2/Sha256";

import Gov "../src/SnsGov";
import L "../src/Logic";

persistent actor class MockGov(ledgerId : Principal, minStake : Nat, votingFloor : Nat64) = this {

  type Account = { owner : Principal; subaccount : ?Blob };
  type Ledger = actor { icrc1_balance_of : (Account) -> async Nat };
  transient let ledger : Ledger = actor (Principal.toText(ledgerId));

  type N = {
    var stake : Nat;
    var delay : Nat64;
    var perms : [(Principal, [Int32])];
  };
  var neurons = Map.empty<Text, N>();
  // Models "the call succeeded on the network but the reply was lost": the delay IS
  // applied, and the caller is told it failed. That is the only way the additive-delay
  // trap can actually fire, so without this switch a test for it is vacuous.
  var configureLie : Nat = 0;
  // Models a governance-side refusal that never clears, for ONE neuron only. The neuron is
  // named by its staking subaccount, which is derived from the entry index, so exactly one
  // entry is wedged. This is the shape of a real permanent per-entry failure, and it is what
  // proves a wedged entry does not hold up the entries behind it.
  var refuseGrantsForSub : ?Blob = null;

  func kof(b : Blob) : Text { debug_show (Blob.toArray(b)) };

  /// `NeuronPermissionType` as SNS Governance actually defines it: ELEVEN values, 0 through
  /// 10 (Unspecified, ConfigureDissolveState, ManagePrincipals, SubmitProposal, Vote,
  /// Disburse, Split, MergeMaturity, DisburseMaturity, StakeMaturity, ManageVotingPermission).
  /// There is no 11. `sns/init` sets both neuron_claimer_permissions and
  /// neuron_grantable_permissions to exactly this set (init/src/lib.rs:813).
  transient let ALL_PERMISSION_TYPES : [Int32] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

  func isGrantable(p : Int32) : Bool {
    for (q in ALL_PERMISSION_TYPES.values()) { if (q == p) return true };
    false;
  };

  /// Governance's two checks, in its order, with its messages. The length check runs FIRST,
  /// so an over-long list is refused before the subset check is ever consulted.
  func validatePermissions(command : Text, requested : [Int32]) : ?Gov.GovernanceError {
    if (requested.size() > ALL_PERMISSION_TYPES.size()) {
      return ?{
        error_type = 3;
        error_message = command # " command provided more permissions than exist in the system";
      };
    };
    for (p in requested.values()) {
      if (not isGrantable(p)) {
        return ?{ error_type = 3; error_message = "Permission " # debug_show (p) # " is not allowed to be granted" };
      };
    };
    null;
  };

  public query func get_nervous_system_parameters() : async Gov.NervousSystemParameters {
    {
      neuron_minimum_dissolve_delay_to_vote_seconds = ?votingFloor;
      neuron_minimum_stake_e8s = ?Nat64.fromNat(minStake);
      transaction_fee_e8s = ?10_000;
      neuron_grantable_permissions = ?{ permissions = ALL_PERMISSION_TYPES };
    };
  };

  public query func get_neuron(a : { neuron_id : ?Gov.NeuronId }) : async Gov.GetNeuronResponse {
    switch (a.neuron_id) {
      case (?nid) {
        switch (Map.get(neurons, Text.compare, kof(nid.id))) {
          case (?n) {
            { result = ?#Neuron({
                id = ?nid;
                cached_neuron_stake_e8s = Nat64.fromNat(n.stake);
                dissolve_state = ?#DissolveDelaySeconds(n.delay);
                // The strip step reads this to remove exactly what it holds.
                permissions = Array.map<(Principal, [Int32]), Gov.NeuronPermission>(
                  n.perms,
                  func(e) { { principal = ?e.0; permission_type = e.1 } },
                );
              }) };
          };
          case null { { result = ?#Error({ error_type = 5; error_message = "not found" }) } };
        };
      };
      case null { { result = ?#Error({ error_type = 3; error_message = "no id" }) } };
    };
  };

  public shared func manage_neuron(m : Gov.ManageNeuron) : async Gov.ManageNeuronResponse {
    let sub = m.subaccount;
    let k = kof(sub);
    switch (m.command) {

      case (?#ClaimOrRefresh(c)) {
        switch (c.by) {
          case (?#MemoAndController(mc)) {
            let controller = switch (mc.controller) { case (?p) p; case null Principal.fromActor(this) };
            // The subaccount the caller funded must be the one derived from (controller, memo).
            let expect = Sha256.fromBlob(#sha256, L.stakingSubaccountPreimage(controller, mc.memo));
            if (expect != sub) {
              return { command = ?#Error({ error_type = 3; error_message = "subaccount does not match (controller, memo)" }) };
            };
            let bal = await ledger.icrc1_balance_of({ owner = Principal.fromActor(this); subaccount = ?sub });
            switch (Map.get(neurons, Text.compare, k)) {
              case (?n) { n.stake := bal; return { command = ?#ClaimOrRefresh({ refreshed_neuron_id = ?{ id = sub } }) } };
              case null {};
            };
            // The trap: under the minimum, the neuron is removed and this errors, but the
            // tokens have already landed in the subaccount.
            if (bal < minStake) {
              return { command = ?#Error({ error_type = 4; error_message = "InsufficientFunds: below neuron_minimum_stake_e8s" }) };
            };
            // Created at dissolve delay ZERO, permissions to the CONTROLLER not the caller.
            Map.add(neurons, Text.compare, k, { var stake = bal; var delay = 0 : Nat64; var perms = [(controller, ALL_PERMISSION_TYPES)] });
            { command = ?#ClaimOrRefresh({ refreshed_neuron_id = ?{ id = sub } }) };
          };
          case (_) { { command = ?#Error({ error_type = 3; error_message = "unsupported By" }) } };
        };
      };

      case (?#Configure(cfg)) {
        switch (Map.get(neurons, Text.compare, k), cfg.operation) {
          case (?n, ?#IncreaseDissolveDelay(op)) {
            // ADDITIVE. This is what makes a blind retry double the delay.
            n.delay := n.delay + Nat64.fromNat(Nat32.toNat(op.additional_dissolve_delay_seconds));
            if (configureLie > 0) {
              configureLie -= 1;
              return { command = ?#Error({ error_type = 1; error_message = "reply lost after the delay was applied" }) };
            };
            { command = ?#Configure({}) };
          };
          case (_, _) { { command = ?#Error({ error_type = 5; error_message = "no neuron or unsupported op" }) } };
        };
      };

      case (?#AddNeuronPermissions(a)) {
        switch (Map.get(neurons, Text.compare, k), a.principal_id, a.permissions_to_add) {
          case (?n, ?p, ?pl) {
            switch (refuseGrantsForSub) {
              case (?blocked) {
                if (blocked == sub) {
                  return { command = ?#Error({ error_type = 6; error_message = "PreconditionFailed: refusing to grant on this neuron" }) };
                };
              };
              case null {};
            };
            switch (validatePermissions("AddNeuronPermissions", pl.permissions)) {
              case (?e) { return { command = ?#Error(e) } };
              case null {};
            };
            let buf = List.empty<(Principal, [Int32])>();
            for (e in n.perms.values()) { if (e.0 != p) List.add(buf, e) };
            List.add(buf, (p, pl.permissions));
            n.perms := List.toArray(buf);
            { command = ?#AddNeuronPermission({}) };
          };
          case (_, _, _) { { command = ?#Error({ error_type = 5; error_message = "bad add" }) } };
        };
      };

      case (?#RemoveNeuronPermissions(r)) {
        switch (Map.get(neurons, Text.compare, k), r.principal_id, r.permissions_to_remove) {
          case (?n, ?p, ?pl) {
            // Governance applies the same length guard to removal (governance.rs:4646).
            if (pl.permissions.size() > ALL_PERMISSION_TYPES.size()) {
              return { command = ?#Error({
                error_type = 3;
                error_message = "RemoveNeuronPermissions command provided more permissions than exist in the system";
              }) };
            };
            let buf = List.empty<(Principal, [Int32])>();
            for (e in n.perms.values()) { if (e.0 != p) List.add(buf, e) };
            n.perms := List.toArray(buf);
            { command = ?#RemoveNeuronPermission({}) };
          };
          case (_, _, _) { { command = ?#Error({ error_type = 5; error_message = "bad remove" }) } };
        };
      };

      case (_) { { command = ?#Error({ error_type = 3; error_message = "unsupported command" }) } };
    };
  };

  // ── inspection, for the harness ─────────────────────────────────────────────────────
  public func setConfigureLie(n : Nat) : async () { configureLie := n };

  /// Refuse every AddNeuronPermissions on this staking subaccount, permanently.
  public func setGrantRefusalForSubaccount(b : ?Blob) : async () { refuseGrantsForSub := b };

  public query func neuronCount() : async Nat { Map.size(neurons) };

  public query func inspect(sub : Blob) : async ?{ stake : Nat; delay : Nat64; perms : [(Principal, [Int32])] } {
    switch (Map.get(neurons, Text.compare, kof(sub))) {
      case (?n) ?{ stake = n.stake; delay = n.delay; perms = n.perms };
      case null null;
    };
  };
}

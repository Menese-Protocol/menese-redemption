/// MockSns.mo: a test SNS in one canister, for the PocketIC mock suite. It answers as SNS
/// root (list_sns_canisters), SNS governance (neurons, Split, Disburse, permissions, mode,
/// parameters), the MPV ledger (balances of staking subaccounts and of disbursal targets),
/// the swap (lifecycle) and NNS SNS-W (list_deployed_snses). The holder canister compiles in
/// the SNS-W id, so this canister is created at that id.
///
/// Governance behaviour follows rs/sns/governance/src/governance.rs (split_neuron,
/// disburse_neuron, add/remove_neuron_permissions) and types.rs (the PreInitializationSwap
/// gate). Every command can be made to fail: return an error, reject before doing anything,
/// or do it and lose the reply.
///
/// Like governance, it lets anyone claim a neuron for any controller at any memo
/// (ClaimOrRefresh by MemoAndController), so a stranger can try to occupy the id of a basket
/// part before the holder canister splits it there. A test control can also occupy the
/// target id of the next Splits as they arrive, which no stranger can do against secret
/// memos: it stands for a race the canister must survive anyway.
///
/// Disburse is modelled although the holder canister cannot send it (its governance
/// interface has no such command): the suite counts Disburse calls and must see none, and
/// the planted fault that puts liquid payments back must be observable here.
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Int32 "mo:core/Int32";
import Principal "mo:core/Principal";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Runtime "mo:core/Runtime";
import Time "mo:core/Time";
import Int "mo:core/Int";
import Sha256 "mo:sha2/Sha256";

persistent actor class MockSns(init : { holder : Principal; stakes : [Nat]; fee : Nat; minStake : Nat }) = this {

  type NeuronId = { id : Blob };
  type Permission = { principal : ?Principal; permission_type : [Int32] };
  type DissolveState = { #DissolveDelaySeconds : Nat64; #WhenDissolvedTimestampSeconds : Nat64 };
  public type Neuron = {
    id : ?NeuronId;
    permissions : [Permission];
    cached_neuron_stake_e8s : Nat64;
    neuron_fees_e8s : Nat64;
    vesting_period_seconds : ?Nat64;
    created_timestamp_seconds : Nat64;
    aging_since_timestamp_seconds : Nat64;
    dissolve_state : ?DissolveState;
  };
  type GovError = { error_type : Int32; error_message : Text };
  type Account = { owner : Principal; subaccount : ?Blob };
  type GovAccount = { owner : ?Principal; subaccount : ?{ subaccount : Blob } };
  type Command = {
    #Split : { memo : Nat64; amount_e8s : Nat64 };
    #Disburse : { to_account : ?GovAccount; amount : ?{ e8s : Nat64 } };
    #AddNeuronPermissions : { principal_id : ?Principal; permissions_to_add : ?{ permissions : [Int32] } };
    #RemoveNeuronPermissions : { principal_id : ?Principal; permissions_to_remove : ?{ permissions : [Int32] } };
  };
  type CommandResponse = {
    #Error : GovError;
    #Split : { created_neuron_id : ?NeuronId };
    #Disburse : { transfer_block_height : Nat64 };
    #AddNeuronPermission : {};
    #RemoveNeuronPermission : {};
  };
  public type Fault = { #error; #reject; #lost };

  let DAY : Nat64 = 86_400;
  let ALL : [Int32] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
  let neurons = Map.empty<Blob, Neuron>();
  let donations = Map.empty<Blob, Nat>();
  let payouts = Map.empty<Text, Nat>();
  let faults = Map.empty<Text, [Fault]>();
  /// Faults for one command on one neuron, used before the command's general queue.
  let faultsAt = Map.empty<Text, [Fault]>();
  /// Faults for one command on any split-off neuron at rung k (dissolve delay k x 182 days),
  /// used after the per-neuron queue: the ids of split-off neurons are secret until split.
  let faultsAtRung = Map.empty<Text, [Fault]>();
  let calls = Map.empty<Text, Nat>();
  /// How many of the next Splits find their target id already taken by a stranger's neuron.
  var occupyNext : Nat = 0;
  /// The ids so occupied, in order.
  let occupied = List.empty<Blob>();
  /// Every injected fault, with the neuron it hit: (command, neuron subaccount, fault).
  let faultLog = List.empty<(Text, Blob, Fault)>();
  var fee : Nat = init.fee;
  var minStake : Nat = init.minStake;
  var grantable : [Int32] = ALL;
  var mode : Int32 = 2;
  var lifecycle : Int32 = 2;
  var termination : ?Nat64 = null;
  var listedBySnsW : Bool = true;
  var answersAsRoot : Bool = true;
  var block : Nat64 = 0;

  func self() : Principal { Principal.fromActor(this) };
  func nowS() : Nat64 { Nat64.fromNat(Int.abs(Time.now()) / 1_000_000_000) };

  public func neuronIdOf(controller : Principal, memo : Nat64) : async Blob { idOf(controller, memo) };
  func idOf(controller : Principal, memo : Nat64) : Blob {
    let pb = Blob.toArray(Principal.toBlob(controller));
    let pre = List.empty<Nat8>();
    List.add(pre, (12 : Nat8));
    for (c in Blob.toArray("neuron-stake").values()) List.add(pre, c);
    for (c in pb.values()) List.add(pre, c);
    var k = 0;
    while (k < 8) { List.add(pre, Nat8.fromNat(Nat64.toNat((memo >> Nat64.fromNat((7 - k) * 8)) & 0xFF))); k += 1 };
    Sha256.fromBlob(#sha256, Blob.fromArray(List.toArray(pre)));
  };

  // Genesis: the holder canister's nine neurons, as SNS initialisation creates developer
  // neurons (rs/sns/init/src/distributions.rs): id = staking subaccount (controller, memo),
  // the claimer holding every permission, a fixed dissolve delay, vesting 0.
  do {
    var k = 0;
    let created = nowS();
    while (k < init.stakes.size()) {
      let id = idOf(init.holder, Nat64.fromNat(k));
      Map.add(neurons, Blob.compare, id, {
        id = ?{ id };
        permissions = [{ principal = ?init.holder; permission_type = ALL }];
        cached_neuron_stake_e8s = Nat64.fromNat(init.stakes[k]);
        neuron_fees_e8s = 0 : Nat64;
        vesting_period_seconds = ?(0 : Nat64);
        created_timestamp_seconds = created;
        aging_since_timestamp_seconds = created;
        dissolve_state = ?#DissolveDelaySeconds(182 * DAY * Nat64.fromNat(k));
      });
      k += 1;
    };
  };

  // ── Test controls ─────────────────────────────────────────────────────────────────
  public func setMode(m : Int32) : async () { mode := m };
  public func setLifecycle(l : Int32, ts : ?Nat64) : async () { lifecycle := l; termination := ts };
  public func setListed(listed : Bool, root : Bool) : async () { listedBySnsW := listed; answersAsRoot := root };
  public func setParams(f : Nat, m : Nat, g : [Int32]) : async () { fee := f; minStake := m; grantable := g };
  public func setFaults(cmd : Text, fs : [Fault]) : async () { Map.add(faults, Text_compare, cmd, fs) };
  public func setFaultsAt(cmd : Text, sub : Blob, fs : [Fault]) : async () { Map.add(faultsAt, Text_compare, cmd # "/" # debug_show (sub), fs) };
  public func setFaultsAtRung(cmd : Text, k : Nat, fs : [Fault]) : async () { Map.add(faultsAtRung, Text_compare, cmd # "@" # Nat.toText(k), fs) };
  public func setOccupyNext(n : Nat) : async () { occupyNext := n };
  public query func occupiedIds() : async [Blob] { List.toArray(occupied) };
  /// ClaimOrRefresh by MemoAndController, which anyone may call for any controller: a new
  /// neuron at the staking subaccount of (controller, memo), the controller holding every
  /// permission, no dissolve delay. Refused if a neuron is already there.
  public func claim(controller : Principal, memo : Nat64, stake : Nat) : async ?Blob {
    let id = idOf(controller, memo);
    if (Map.get(neurons, Blob.compare, id) != null) return null;
    Map.add(neurons, Blob.compare, id, stranger(id, controller, stake));
    ?id;
  };
  public query func faultsLeft(cmd : Text) : async Nat { switch (Map.get(faults, Text_compare, cmd)) { case (?f) f.size(); case null 0 } };
  public query func callsOf(cmd : Text) : async Nat { switch (Map.get(calls, Text_compare, cmd)) { case (?n) n; case null 0 } };
  public func donate(sub : Blob, amount : Nat) : async () {
    Map.add(donations, Blob.compare, sub, amount + (switch (Map.get(donations, Blob.compare, sub)) { case (?d) d; case null 0 }));
  };
  /// ClaimOrRefresh by neuron id, which anyone may call: the neuron's stake catches up
  /// with its subaccount's balance (a donation becomes stake).
  public func refresh(sub : Blob) : async () {
    switch (Map.get(neurons, Blob.compare, sub), Map.get(donations, Blob.compare, sub)) {
      case (?n, ?d) {
        Map.add(neurons, Blob.compare, sub, { n with cached_neuron_stake_e8s = n.cached_neuron_stake_e8s + Nat64.fromNat(d) });
        Map.remove(donations, Blob.compare, sub);
      };
      case _ {};
    };
  };
  public func ping() : async () {};
  public query func allNeurons() : async [Neuron] { Array.fromIter(Map.values(neurons)) };
  public query func getFaultLog() : async [(Text, Blob, Fault)] { List.toArray(faultLog) };
  public query func payoutOf(owner : Principal) : async Nat {
    switch (Map.get(payouts, Text_compare, acctKey({ owner; subaccount = null }))) { case (?v) v; case null 0 };
  };

  func Text_compare(a : Text, b : Text) : { #less; #equal; #greater } { if (a < b) #less else if (a > b) #greater else #equal };

  func pop(m : Map.Map<Text, [Fault]>, key : Text) : ?Fault {
    switch (Map.get(m, Text_compare, key)) {
      case (?fs) {
        if (fs.size() == 0) return null;
        Map.add(m, Text_compare, key, Array.sliceToArray<Fault>(fs, 1, fs.size()));
        ?fs[0];
      };
      case null null;
    };
  };

  func stranger(id : Blob, controller : Principal, stake : Nat) : Neuron {
    let now = nowS();
    { id = ?{ id }; permissions = [{ principal = ?controller; permission_type = ALL }];
      cached_neuron_stake_e8s = Nat64.fromNat(stake); neuron_fees_e8s = 0 : Nat64; vesting_period_seconds = null : ?Nat64;
      created_timestamp_seconds = now; aging_since_timestamp_seconds = now; dissolve_state = ?#DissolveDelaySeconds(0 : Nat64) };
  };

  func isGenesis(sub : Blob) : Bool {
    var k = 0;
    while (k < init.stakes.size()) { if (idOf(init.holder, Nat64.fromNat(k)) == sub) return true; k += 1 };
    false;
  };

  /// The rung of a split-off neuron, from its dissolve delay.
  func rungOf(sub : Blob) : ?Nat {
    if (isGenesis(sub)) return null;
    switch (Map.get(neurons, Blob.compare, sub)) {
      case (?n) {
        switch (n.dissolve_state) {
          case (?#DissolveDelaySeconds(d)) { if (d % (182 * DAY) == 0) ?Nat64.toNat(d / (182 * DAY)) else null };
          case _ null;
        };
      };
      case null null;
    };
  };

  func nextFaultAt(cmd : Text, sub : Blob) : ?Fault {
    switch (pop(faultsAt, cmd # "/" # debug_show (sub))) {
      case (?f) return ?f;
      case null {};
    };
    switch (rungOf(sub)) {
      case (?k) { switch (pop(faultsAtRung, cmd # "@" # Nat.toText(k))) { case (?f) return ?f; case null {} } };
      case null {};
    };
    nextFault(cmd);
  };

  func nextFault(cmd : Text) : ?Fault {
    Map.add(calls, Text_compare, cmd, 1 + (switch (Map.get(calls, Text_compare, cmd)) { case (?n) n; case null 0 }));
    switch (Map.get(faults, Text_compare, cmd)) {
      case (?fs) {
        if (fs.size() == 0) return null;
        Map.add(faults, Text_compare, cmd, Array.sliceToArray<Fault>(fs, 1, fs.size()));
        ?fs[0];
      };
      case null null;
    };
  };

  func err(t : Int32, m : Text) : { command : ?CommandResponse } { { command = ?#Error({ error_type = t; error_message = m }) } };

  func authorized(n : Neuron, who : Principal, perm : Int32) : Bool {
    for (p in n.permissions.values()) {
      switch (p.principal) {
        case (?q) { if (Principal.equal(q, who) and Array.find<Int32>(p.permission_type, func(x) { x == perm }) != null) return true };
        case null {};
      };
    };
    false;
  };

  func acctKey(a : Account) : Text {
    Principal.toText(a.owner) # "/" # (switch (a.subaccount) { case (?s) debug_show (s); case null "" });
  };

  // ── SNS governance ────────────────────────────────────────────────────────────────
  public shared ({ caller }) func manage_neuron(arg : { subaccount : Blob; command : ?Command }) : async { command : ?CommandResponse } {
    let cmdName = switch (arg.command) {
      case (?#Split(_)) "split"; case (?#Disburse(_)) "disburse";
      case (?#AddNeuronPermissions(_)) "add"; case (?#RemoveNeuronPermissions(_)) "remove"; case null "none";
    };
    let fault = nextFaultAt(cmdName, arg.subaccount);
    switch (fault) { case (?f) List.add(faultLog, (cmdName, arg.subaccount, f)); case null {} };
    switch (fault) {
      // The fault is consumed and logged (committed by the await), then the call is
      // rejected before it acts. Trapping without the await would roll the consumption
      // back and the same reject would fire forever.
      case (?#reject) { await ping(); Runtime.trap("injected reject before " # cmdName) };
      case (?#error) return err(15, "injected error on " # cmdName);
      case _ {};
    };
    switch (arg.command) {
      case (?#Split(sp)) {
        let target = idOf(caller, sp.memo);
        if (occupyNext > 0 and Map.get(neurons, Blob.compare, target) == null) {
          // A stranger got there first, with a neuron claimed for the holder canister as its
          // controller and exactly the split's stake, so it looks like the part.
          Map.add(neurons, Blob.compare, target, stranger(target, caller, Nat.sub(Nat.max(Nat64.toNat(sp.amount_e8s), fee), fee)));
          List.add(occupied, target);
          occupyNext -= 1;
        };
      };
      case _ {};
    };
    let r = perform(caller, arg.subaccount, arg.command);
    if (fault == ?#lost) {
      // The command took effect; commit it, then lose the reply.
      await ping();
      Runtime.trap("injected lost reply after " # cmdName);
    };
    r;
  };

  func perform(caller : Principal, sub : Blob, command : ?Command) : { command : ?CommandResponse } {
    let n = switch (Map.get(neurons, Blob.compare, sub)) { case (?n) n; case null return err(4, "neuron not found") };
    switch (command) {
      case (?#Split(s)) {
        if (mode != 1) return err(9, "PreInitializationSwap: Split not allowed");
        if (not authorized(n, caller, 6)) return err(3, "not authorized to Split");
        switch (n.vesting_period_seconds) { case (?v) { if (n.created_timestamp_seconds + v >= nowS()) return err(9, "vesting") }; case null {} };
        let amount = Nat64.toNat(s.amount_e8s);
        if (amount < minStake + fee) return err(6, "split amount too small");
        let stake = Nat64.toNat(n.cached_neuron_stake_e8s) - Nat64.toNat(n.neuron_fees_e8s);
        if (stake < minStake + amount) return err(6, "parent would fall under the minimum");
        let cid = idOf(caller, s.memo);
        if (Map.get(neurons, Blob.compare, cid) != null) return err(9, "a neuron with this id already exists");
        Map.add(neurons, Blob.compare, sub, { n with cached_neuron_stake_e8s = n.cached_neuron_stake_e8s - s.amount_e8s });
        Map.add(neurons, Blob.compare, cid, { n with id = ?{ id = cid }; cached_neuron_stake_e8s = Nat64.fromNat(amount - fee);
                                              neuron_fees_e8s = 0 : Nat64; vesting_period_seconds = null : ?Nat64; created_timestamp_seconds = nowS() });
        block += 1;
        { command = ?#Split({ created_neuron_id = ?{ id = cid } }) };
      };
      case (?#Disburse(d)) {
        if (mode != 1) return err(9, "PreInitializationSwap: Disburse not allowed");
        if (not authorized(n, caller, 5)) return err(3, "not authorized to Disburse");
        switch (n.dissolve_state) { case (?#DissolveDelaySeconds(0)) {}; case _ return err(9, "neuron is not dissolved") };
        let stake = Nat64.toNat(n.cached_neuron_stake_e8s);
        let amount = switch (d.amount) { case (?a) Nat.min(Nat64.toNat(a.e8s), stake); case null stake };
        if (amount <= fee) return err(6, "amount at or below the fee");
        let to : Account = switch (d.to_account) {
          case (?a) { { owner = switch (a.owner) { case (?o) o; case null caller }; subaccount = switch (a.subaccount) { case (?s) ?s.subaccount; case null null } } };
          case null { { owner = caller; subaccount = null } };
        };
        Map.add(neurons, Blob.compare, sub, { n with cached_neuron_stake_e8s = Nat64.fromNat(stake - amount) });
        let key = acctKey(to);
        Map.add(payouts, Text_compare, key, (amount - fee) + (switch (Map.get(payouts, Text_compare, key)) { case (?v) v; case null 0 }));
        block += 1;
        { command = ?#Disburse({ transfer_block_height = block }) };
      };
      case (?#AddNeuronPermissions(a)) {
        if (not authorized(n, caller, 2)) return err(3, "not authorized to manage principals");
        let who = switch (a.principal_id) { case (?p) p; case null return err(2, "no principal") };
        let add = switch (a.permissions_to_add) { case (?l) l.permissions; case null [] };
        for (x in add.values()) { if (Array.find<Int32>(grantable, func(y) { y == x }) == null) return err(2, "permission not grantable") };
        var found = false;
        let perms = Array.map<Permission, Permission>(n.permissions, func(p) {
          switch (p.principal) {
            case (?q) {
              if (Principal.equal(q, who)) {
                found := true;
                let merged = List.fromArray<Int32>(p.permission_type);
                for (x in add.values()) { if (Array.find<Int32>(p.permission_type, func(y) { y == x }) == null) List.add(merged, x) };
                { p with permission_type = List.toArray(merged) };
              } else p;
            };
            case null p;
          };
        });
        let next = if (found) perms else Array.concat<Permission>(perms, [{ principal = ?who; permission_type = add }]);
        Map.add(neurons, Blob.compare, sub, { n with permissions = next });
        { command = ?#AddNeuronPermission({}) };
      };
      case (?#RemoveNeuronPermissions(r)) {
        if (not authorized(n, caller, 2)) return err(3, "not authorized to manage principals");
        let who = switch (r.principal_id) { case (?p) p; case null return err(2, "no principal") };
        let rem = switch (r.permissions_to_remove) { case (?l) l.permissions; case null [] };
        let next = List.empty<Permission>();
        var had = false;
        for (p in n.permissions.values()) {
          switch (p.principal) {
            case (?q) {
              if (Principal.equal(q, who)) {
                had := true;
                let keep = Array.filter<Int32>(p.permission_type, func(x) { Array.find<Int32>(rem, func(y) { y == x }) == null });
                if (keep.size() > 0) List.add(next, { p with permission_type = keep });
              } else List.add(next, p);
            };
            case null List.add(next, p);
          };
        };
        if (not had) return err(4, "principal has no permissions on this neuron");
        Map.add(neurons, Blob.compare, sub, { n with permissions = List.toArray(next) });
        { command = ?#RemoveNeuronPermission({}) };
      };
      case null err(2, "no command");
    };
  };

  public shared func get_neuron(arg : { neuron_id : ?NeuronId }) : async { result : ?{ #Error : GovError; #Neuron : Neuron } } {
    switch (nextFault("get_neuron")) { case (?#reject) { await ping(); Runtime.trap("injected reject on get_neuron") }; case _ {} };
    let id = switch (arg.neuron_id) { case (?i) i.id; case null return { result = ?#Error({ error_type = 4; error_message = "no id" }) } };
    switch (Map.get(neurons, Blob.compare, id)) {
      case (?n) { { result = ?#Neuron(n) } };
      case null { { result = ?#Error({ error_type = 4; error_message = "No neuron for given NeuronId." }) } };
    };
  };

  public query func get_nervous_system_parameters() : async {
    neuron_minimum_dissolve_delay_to_vote_seconds : ?Nat64; neuron_minimum_stake_e8s : ?Nat64;
    transaction_fee_e8s : ?Nat64; max_dissolve_delay_seconds : ?Nat64;
    neuron_grantable_permissions : ?{ permissions : [Int32] };
  } {
    { neuron_minimum_dissolve_delay_to_vote_seconds = ?(182 * DAY); neuron_minimum_stake_e8s = ?Nat64.fromNat(minStake);
      transaction_fee_e8s = ?Nat64.fromNat(fee); max_dissolve_delay_seconds = ?(1461 * DAY);
      neuron_grantable_permissions = ?{ permissions = grantable } };
  };

  public query func get_mode(_ : {}) : async { mode : ?Int32 } { { mode = ?mode } };

  // ── The MPV ledger ────────────────────────────────────────────────────────────────
  public shared func icrc1_balance_of(a : Account) : async Nat {
    switch (nextFault("balance")) { case (?#reject) { await ping(); Runtime.trap("injected reject on balance") }; case _ {} };
    if (Principal.equal(a.owner, self())) {
      switch (a.subaccount) {
        case (?s) {
          let staked = switch (Map.get(neurons, Blob.compare, s)) { case (?n) Nat64.toNat(n.cached_neuron_stake_e8s); case null 0 };
          let d = switch (Map.get(donations, Blob.compare, s)) { case (?d) d; case null 0 };
          return staked + d;
        };
        case null return 0;
      };
    };
    switch (Map.get(payouts, Text_compare, acctKey(a))) { case (?v) v; case null 0 };
  };

  // ── Swap, root, SNS-W ─────────────────────────────────────────────────────────────
  public query func get_lifecycle(_ : {}) : async { lifecycle : ?Int32; decentralization_sale_open_timestamp_seconds : ?Nat64; decentralization_swap_termination_timestamp_seconds : ?Nat64 } {
    { lifecycle = ?lifecycle; decentralization_sale_open_timestamp_seconds = null; decentralization_swap_termination_timestamp_seconds = termination };
  };

  public query func list_sns_canisters(_ : {}) : async { root : ?Principal; swap : ?Principal; ledger : ?Principal; index : ?Principal; governance : ?Principal; dapps : [Principal]; archives : [Principal] } {
    let s = self();
    if (not answersAsRoot) return { root = null; swap = null; ledger = null; index = null; governance = null; dapps = []; archives = [] };
    { root = ?s; swap = ?s; ledger = ?s; index = null; governance = ?s; dapps = [init.holder]; archives = [] };
  };

  public query func list_deployed_snses(_ : {}) : async { instances : [{ root_canister_id : ?Principal; governance_canister_id : ?Principal; ledger_canister_id : ?Principal; swap_canister_id : ?Principal; index_canister_id : ?Principal }] } {
    let s = self();
    if (not listedBySnsW) return { instances = [] };
    { instances = [{ root_canister_id = ?s; governance_canister_id = ?s; ledger_canister_id = ?s; swap_canister_id = ?s; index_canister_id = null }] };
  };
}

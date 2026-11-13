/// Redemption.mo: the MPV holder canister.
///
/// Holds the MENES holders' 15% of MPV as its own nine genesis neurons (dissolve delays 0,
/// 182, ..., 1,456 days), created by the SNS itself at genesis. When the swap commits, it
/// takes the holder snapshot itself from the MENES ledger and the MENES sale canister,
/// publishes the table and its hash, and delivers every holder's share out of those
/// neurons: a basket of one to nine neurons, each split off a genesis neuron (each child
/// keeps its parent's dissolve delay and age). No DAO proposal is ever needed.
///
/// The properties an auditor checks first:
///
///   1. There is NO admin and NO init argument. Everything it acts on is compiled in (the
///      MENES ledger and sale canister, the NNS SNS-W, the exclusions) or read from the IC
///      itself after genesis (its controllers, the SNS that lists it, the swap's close,
///      its own genesis neurons). The module hash fixes all of it.
///   2. It cannot mint and holds nothing but its genesis neurons. It can only hand them out
///      by the table, and the table is built once by a fixed rule and never changed.
///   3. Every check of the snapshot fails closed: on any disagreement nobody is paid.
///   4. Status is written BEFORE the call it guards, never after; every call whose reply
///      can be lost has an oracle that tells whether it happened.
///
/// Design: docs/DESIGN.md

import Principal "mo:core/Principal";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Int "mo:core/Int";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import Text "mo:core/Text";
import List "mo:core/List";
import Map "mo:core/Map";
import Timer "mo:core/Timer";
import Result "mo:core/Result";
import Time "mo:core/Time";
import Error "mo:core/Error";
import Sha256 "mo:sha2/Sha256";

import T "Types";
import L "Logic";
import I "Ifaces";
import Gov "SnsGov";
import X "Exclusions";

persistent actor Redemption {

  // ── Compiled in ─────────────────────────────────────────────────────────────────────
  let MENES_LEDGER : Principal = Principal.fromText("drgmr-ayaaa-aaaab-aereq-cai");
  let MENES_SALE : Principal = Principal.fromText("d7ebz-3iaaa-aaaab-aerfq-cai");
  let SNS_W : Principal = Principal.fromText("qaa6y-5yaaa-aaaaa-aaafa-cai");
  /// Blocks asked for per get_transactions call.
  let BLOCK_BATCH : Nat = 2_000;
  /// Stake records read in parallel per step.
  let STAKE_BATCH : Nat = 32;
  /// The ledger is read to its tip only this long after the stakes were read, so a payment
  /// for a withdrawal the sale canister had already recorded is in the ledger.
  let SETTLE_NS : Int = 600_000_000_000;
  /// Rounds of (stakes, blocks to the tip, stakes again) before disagreement halts.
  let MAX_STAKE_ROUNDS : Nat = 5;
  /// Delivery steps per timer tick.
  let STEPS_PER_TICK : Nat = 12;

  // ── State ───────────────────────────────────────────────────────────────────────────
  var phase : T.Phase = #Unbound;
  var binding : ?T.Binding = null;
  var note : Text = "waiting for SNS root to be the sole controller";
  var closeSeconds : Nat64 = 0;

  // Snapshot working state.
  type SnapStep = { #Genesis; #StakesA; #Blocks; #Supply; #StakesB; #Compute };
  var snapStep : SnapStep = #Genesis;
  var genesis : [Nat] = [];
  var fee : Nat = 0;
  var minStake : Nat = 0;
  var stakesA : [T.StakeInfo] = [];
  let stakeBuf = List.empty<T.StakeInfo>();
  var stakeNext : Nat = 0;
  var stakeMisses : Nat = 0;
  var stakeRounds : Nat = 0;
  var settleUntil : Int = 0;
  var blockNext : Nat = 0;
  var cut : ?Nat = null;
  var lastFoldedTs : Nat64 = 0;
  let balances = Map.empty<Principal, Int>();
  var supplyAll : Int = 0;
  let saleAfterCut = List.empty<(Nat, Principal, Nat)>();
  var tip : Nat = 0;
  var supplyReported : Nat = 0;
  let checks = List.empty<Text>();

  // The table, once built. Never changed afterwards.
  var entries : [T.Entry] = [];
  var dropped : [T.Dropped] = [];
  var progress : [var T.Progress] = [var];
  var report : ?T.SnapshotReport = null;
  let ownerIndex = Map.empty<Principal, [Nat]>();

  // Delivery books, per genesis neuron k.
  let takenFrom : [var Nat] = VarArray.repeat<Nat>(0, L.NEURONS);
  /// The entry whose operation on genesis neuron k is sent and not yet confirmed. While it
  /// is set, nothing else touches neuron k, so the neuron's balance is an exact oracle.
  let parentBusy : [var ?Nat] = VarArray.repeat<?Nat>(null, L.NEURONS);
  /// The entry that received genesis neuron k itself.
  let handedTo : [var ?Nat] = VarArray.repeat<?Nat>(null, L.NEURONS);
  var splits : Nat = 0;
  /// The secret behind every split memo (Logic.splitMemo): drawn once from the IC's
  /// randomness before the first split, and never returned by any method.
  var memoSeed : ?Blob = null;
  /// The memo step of each part (key entry x NEURONS + k): 0, and one more each time the
  /// part's id is found occupied before its split.
  let memoStep = Map.empty<Nat, Nat>();
  /// Neurons found at a part's id before its split: never made by this canister, left
  /// alone, outside the books.
  let foreign = List.empty<T.Foreign>();

  var tick : Nat = 0;
  var consecutiveFailures : Nat = 0;
  var cursor : Nat = 0;
  transient var driving : Bool = false;

  func self() : Principal { Principal.fromActor(Redemption) };
  func mgmt() : I.Management { actor ("aaaaa-aa") };
  func govOf(b : T.Binding) : Gov.Service { actor (Principal.toText(b.governance)) };
  func mpvOf(b : T.Binding) : I.SnsLedger { actor (Principal.toText(b.ledger)) };
  func menes() : I.MenesLedger { actor (Principal.toText(MENES_LEDGER)) };
  func sale() : I.MenesSale { actor (Principal.toText(MENES_SALE)) };

  func subaccount(memo : Nat64) : Blob { Sha256.fromBlob(#sha256, L.stakingSubaccountPreimage(self(), memo)) };
  func parentId(k : Nat) : Blob { subaccount(Nat64.fromNat(k)) };
  func stepOf(i : Nat, k : Nat) : Nat { switch (Map.get(memoStep, Nat.compare, i * L.NEURONS + k)) { case (?s) s; case null 0 } };
  func memoOf(seed : Blob, i : Nat, k : Nat) : Nat64 { L.splitMemo(seed, i, k, stepOf(i, k)) };

  func check(line : Text) { List.add(checks, line) };
  func halt(why : Text) { check("HALTED: " # why); phase := #Halted(why); note := why };

  // ── Binding after genesis ───────────────────────────────────────────────────────────
  func stepBind() : async* () {
    let info = await mgmt().canister_info({ canister_id = self(); num_requested_changes = null });
    switch (L.soleController(info.controllers)) {
      case null { note := "waiting for SNS root to be the sole controller (controllers: " # Nat.toText(info.controllers.size()) # ")" };
      case (?c) {
        let root : I.SnsRoot = actor (Principal.toText(c));
        let answer = try { ?(await root.list_sns_canisters({})) } catch (_) { null };
        switch (answer) {
          case null { note := "the sole controller does not answer as an SNS root" };
          case (?a) {
            switch (L.bindingFrom(c, a, self(), Time.now())) {
              case null { note := "the sole controller is not an SNS root listing this canister" };
              case (?b) {
                let snsw : I.SnsWasm = actor (Principal.toText(SNS_W));
                let deployed = await snsw.list_deployed_snses({});
                if (binding == null and phase == #Unbound) {
                  if (L.deployedByNns(b, deployed.instances)) {
                    binding := ?b;
                    phase := #AwaitClose;
                    note := "bound";
                  } else {
                    note := Principal.toText(c) # " answers as an SNS root but NNS SNS-W does not list that SNS";
                  };
                };
              };
            };
          };
        };
      };
    };
  };

  // ── The swap's close ────────────────────────────────────────────────────────────────
  func stepClose(b : T.Binding) : async* () {
    let swap : I.Swap = actor (Principal.toText(b.swap));
    let l = await swap.get_lifecycle({});
    if (phase != #AwaitClose) return;
    switch (l.lifecycle, l.decentralization_swap_termination_timestamp_seconds) {
      case (?3, ?ts) {
        closeSeconds := ts;
        check("close       the swap committed; closed at " # Nat64.toText(ts) # " s");
        phase := #Snapshot;
        snapStep := #Genesis;
        note := "taking the snapshot";
      };
      case (?4, _) { phase := #Aborted; note := "the swap was aborted: nothing to deliver" };
      case (_, _) { note := "waiting for the swap to commit" };
    };
  };

  // ── The snapshot, one step per tick ─────────────────────────────────────────────────
  func stepSnapshot(b : T.Binding) : async* () {
    switch (snapStep) {
      case (#Genesis) await* stepGenesis(b);
      case (#StakesA) await* stepStakes(true);
      case (#Blocks) await* stepBlocks();
      case (#Supply) await* stepSupply();
      case (#StakesB) await* stepStakes(false);
      case (#Compute) stepCompute(b);
    };
  };

  /// Reads the nine genesis neurons and the parameters the table depends on.
  func stepGenesis(b : T.Binding) : async* () {
    let gov = govOf(b);
    let p = await gov.get_nervous_system_parameters();
    let (f, m) = switch (p.transaction_fee_e8s, p.neuron_minimum_stake_e8s) {
      case (?f, ?m) (Nat64.toNat(f), Nat64.toNat(m));
      case _ return halt("governance did not report the fee and the minimum stake");
    };
    let now = Nat64.fromNat(Int.abs(Time.now()) / 1_000_000_000);
    let stakes = VarArray.repeat<Nat>(0, L.NEURONS);
    var k = 0;
    while (k < L.NEURONS) {
      let r = await gov.get_neuron({ neuron_id = ?{ id = parentId(k) } });
      switch (r.result) {
        case (?#Neuron(n)) {
          switch (L.genesisRefusal(k, n, self(), now)) {
            case (?why) return halt(why);
            case null { stakes[k] := Nat64.toNat(n.cached_neuron_stake_e8s) };
          };
        };
        case _ return halt("genesis neuron " # Nat.toText(k) # " does not exist");
      };
      k += 1;
    };
    var sum : Nat = 0;
    for (s in stakes.values()) sum += s;
    check("genesis     neurons 0..8 hold " # debug_show (Array.fromVarArray(stakes)) # " e8s, delays 0..1456 days, controlled by this canister");
    if (sum != L.POOL_E8S) return halt("the genesis neurons hold " # Nat.toText(sum) # " e8s, not 15,000,000 MPV");
    check("genesis     sum = 15,000,000 MPV  OK; fee " # Nat.toText(f) # " e8s, minimum stake " # Nat.toText(m) # " e8s");
    genesis := Array.fromVarArray(stakes);
    fee := f;
    minStake := m;
    snapStep := #StakesA;
    stakeNext := 0;
    stakeMisses := 0;
    List.clear(stakeBuf);
  };

  /// Reads the sale canister's stake records 0, 1, 2, ... until 64 ids in a row are missing.
  func stepStakes(first : Bool) : async* () {
    note := "reading the sale canister's stake records" # (if (first) "" else " again");
    let futures = List.empty<async ?T.StakeInfo>();
    var j = 0;
    while (j < STAKE_BATCH) { List.add(futures, sale().getStakeInfo(stakeNext + j)); j += 1 };
    let got = List.empty<?T.StakeInfo>();
    for (fut in List.values(futures)) { List.add(got, await fut) };
    for (r in List.values(got)) {
      if (stakeMisses < L.STAKE_MISSES_TO_STOP) {
        switch (r) {
          case (?s) { List.add(stakeBuf, s); stakeMisses := 0 };
          case null { stakeMisses += 1 };
        };
      };
    };
    stakeNext += STAKE_BATCH;
    if (stakeMisses < L.STAKE_MISSES_TO_STOP) return;
    let read = List.toArray(stakeBuf);
    List.clear(stakeBuf);
    stakeNext := 0;
    stakeMisses := 0;
    if (first) {
      stakesA := read;
      check("stakes      read " # Nat.toText(read.size()) # " stake records (round " # Nat.toText(stakeRounds + 1) # ")");
      settleUntil := Time.now() + SETTLE_NS;
      snapStep := #Blocks;
    } else {
      stakeRounds += 1;
      if (L.sameStakes(stakesA, read)) {
        check("stakes      read again after the ledger tip: identical");
        snapStep := #Compute;
      } else if (stakeRounds >= MAX_STAKE_ROUNDS) {
        halt("the stake records kept changing while the ledger was read (" # Nat.toText(stakeRounds) # " rounds)");
      } else {
        check("stakes      read again after the ledger tip: changed; reading the ledger on to its new tip");
        stakesA := read;
        settleUntil := Time.now() + SETTLE_NS;
        snapStep := #Blocks;
      };
    };
  };

  func fold(index : Nat, t : I.Transaction) : ?Text {
    let e = switch (L.effectOf(t)) { case (#ok(e)) e; case (#err(why)) return ?("block " # Nat.toText(index) # ": " # why) };
    supplyAll += e.supply;
    let before = L.beforeClose(t.timestamp, closeSeconds);
    switch (cut) {
      case null {
        if (before) {
          for ((p, d) in e.deltas.values()) {
            let cur = switch (Map.get(balances, Principal.compare, p)) { case (?v) v; case null 0 };
            Map.add(balances, Principal.compare, p, cur + d);
          };
          lastFoldedTs := t.timestamp;
          return null;
        };
        cut := ?index;
      };
      case (?_) {
        if (before) return ?("block " # Nat.toText(index) # " is timestamped at or before the close but comes after a later block");
      };
    };
    // After the cut: only payments out of the sale canister matter, to resolve withdrawals.
    switch (t.transfer) {
      case (?x) { if (Principal.equal(x.from.owner, MENES_SALE)) List.add(saleAfterCut, (index, x.to.owner, x.amount)) };
      case null {};
    };
    null;
  };

  /// Walks the MENES ledger from block 0 to its tip, following the archives.
  func stepBlocks() : async* () {
    if (Time.now() < settleUntil) { note := "waiting for the ledger to settle after the stake read"; return };
    let r = await menes().get_transactions({ start = blockNext; length = BLOCK_BATCH });
    tip := r.log_length;
    if (blockNext >= r.log_length) { snapStep := #Supply; return };
    let pieces = List.empty<(Nat, [I.Transaction])>();
    for (a in r.archived_transactions.values()) {
      let want = Nat.min(a.length, BLOCK_BATCH);
      let got = await a.callback({ start = a.start; length = want });
      List.add(pieces, (a.start, got.transactions));
    };
    List.add(pieces, (r.first_index, r.transactions));
    let spans = List.toArray(List.map<(Nat, [I.Transaction]), (Nat, Nat)>(pieces, func((s, txs)) { (s, txs.size()) }));
    let run = L.contiguousFrom(blockNext, spans);
    if (run == 0) return halt("missing block: the ledger reports " # Nat.toText(r.log_length) # " blocks but block " # Nat.toText(blockNext) # " could not be read");
    var idx = blockNext;
    while (idx < blockNext + run) {
      var tx : ?I.Transaction = null;
      for ((s, txs) in List.values(pieces)) {
        if (tx == null and s <= idx and idx < s + txs.size()) tx := ?txs[idx - s];
      };
      switch (tx) {
        case (?t) { switch (fold(idx, t)) { case (?why) return halt(why); case null {} } };
        case null return halt("missing block " # Nat.toText(idx));
      };
      idx += 1;
    };
    blockNext += run;
    note := "read " # Nat.toText(blockNext) # " of " # Nat.toText(r.log_length) # " MENES blocks";
    if (blockNext >= r.log_length) snapStep := #Supply;
  };

  /// The supply rebuilt from every block must equal what the ledger reports for the same
  /// length; the length is read after the supply, so no block came in between.
  func stepSupply() : async* () {
    note := "checking the supply rebuilt from the blocks against the ledger's";
    let s = await menes().icrc1_total_supply();
    let r = await menes().get_transactions({ start = blockNext; length = 0 });
    if (r.log_length != blockNext) { snapStep := #Blocks; return };
    tip := blockNext;
    supplyReported := s;
    if (cut == null) cut := ?blockNext;
    let c = switch (cut) { case (?c) c; case null blockNext };
    check("ledger      " # Nat.toText(blockNext) # " blocks read; " # Nat.toText(c) # " at or before the close; last folded block at " # Nat64.toText(lastFoldedTs) # " ns");
    if (supplyAll != s) return halt("the supply rebuilt from the blocks (" # Int.toText(supplyAll) # ") is not icrc1_total_supply (" # Nat.toText(s) # ")");
    check("ledger      supply rebuilt from every block = icrc1_total_supply = " # Nat.toText(s) # "  OK");
    snapStep := #StakesB;
  };

  /// Builds the table from what the steps gathered, or halts on the first failed check.
  func stepCompute(b : T.Binding) {
    // Stakes at the close.
    let existed = Array.filter<T.StakeInfo>(stakesA, func(s) { L.existedAtClose(s, closeSeconds) });
    let inactive = Array.filter<T.StakeInfo>(existed, func(s) { not s.active });
    switch (L.unresolvedWithdrawal(inactive, List.toArray(saleAfterCut))) {
      case (?(id, block)) return halt("stake " # Nat.toText(id) # " may have been withdrawn after the cut (block " # Nat.toText(block) # "); its state at the close cannot be read");
      case null {};
    };
    let staked = Map.empty<Principal, Nat>();
    var activeTotal : Nat = 0;
    for (s in existed.values()) {
      if (s.active) {
        let cur = switch (Map.get(staked, Principal.compare, s.owner)) { case (?v) v; case null 0 };
        Map.add(staked, Principal.compare, s.owner, cur + s.amount);
        activeTotal += s.amount;
      };
    };
    let saleBal : Int = switch (Map.get(balances, Principal.compare, MENES_SALE)) { case (?v) v; case null 0 };
    check("stakes      " # Nat.toText(existed.size()) # " existed at the close, " # Nat.toText(existed.size() - inactive.size()) # " active, " # Nat.toText(activeTotal) # " e8s; " # Nat.toText(saleAfterCut.size()) # " payments out of the sale canister after the cut, none of them a withdrawal");
    if (activeTotal > saleBal) return halt("the active stakes (" # Nat.toText(activeTotal) # ") exceed what the sale canister holds at the cut (" # Int.toText(saleBal) # ")");
    check("stakes      the sale canister holds " # Int.toText(saleBal) # " e8s at the cut; the active stakes are within it  OK");
    // Balances at the cut, and the exclusions per principal and per kind.
    let owners = Map.empty<Principal, (Nat, Nat)>();
    for ((p, v) in Map.entries(balances)) {
      if (v < 0) return halt("negative balance for " # Principal.toText(p) # " at the cut");
      let held : Nat = if (L.contains(X.heldAndStaked, p) or L.contains(X.heldOnly, p)) 0 else Int.abs(v);
      if (held > 0) Map.add(owners, Principal.compare, p, (held, 0));
    };
    for ((p, s) in Map.entries(staked)) {
      if (not (L.contains(X.heldAndStaked, p) or L.contains(X.stakedOnly, p))) {
        let (h, _) = switch (Map.get(owners, Principal.compare, p)) { case (?x) x; case null (0, 0) };
        Map.add(owners, Principal.compare, p, (h, s));
      };
    };
    // Only holders with something left after the exclusions are eligible.
    let rows = Array.sort<(Principal, (Nat, Nat))>(
      Array.filter<(Principal, (Nat, Nat))>(Iter_toArray(Map.entries(owners)), func((_, (h, s))) { h + s > 0 }),
      func(a, b2) { L.byText(a.0, b2.0) });
    let weights = Array.map<(Principal, (Nat, Nat)), Nat>(rows, func((_, (h, s))) { h + s });
    switch (L.allocate(weights, genesis, fee, minStake)) {
      case (#err(why)) return halt(why);
      case (#ok(a)) {
        let table = Array.tabulate<T.Entry>(a.kept.size(), func(j) {
          let r = rows[a.kept[j]];
          { owner = r.0; held = r.1.0; staked = r.1.1; gross = a.gross[j];
            firstRung = a.firstRung[j]; neurons = a.neurons[j] };
        });
        let left = Array.map<Nat, T.Dropped>(a.dropped, func(i) { { owner = rows[i].0; held = rows[i].1.0; staked = rows[i].1.1 } });
        let hash = Sha256.fromBlob(#sha256, L.tableBytes(table, left, fee, minStake, genesis));
        var nFull = 0; var nSmall = 0; var nNeurons = 0;
        for (e in table.values()) {
          if (e.neurons.size() == L.NEURONS) nFull += 1 else nSmall += 1;
          nNeurons += e.neurons.size();
        };
        var droppedWeight : Nat = 0;
        for (d in left.values()) droppedWeight += d.held + d.staked;
        check("table       " # Nat.toText(rows.size()) # " holders: " # Nat.toText(table.size()) # " in the table (" # Nat.toText(nFull) # " baskets of nine, " # Nat.toText(nSmall) # " smaller, " # Nat.toText(nNeurons) # " neurons); " # Nat.toText(left.size()) # " below one minimum neuron left out, their share spread pro rata (" # Nat.toText(a.dropRounds) # " rounds)");
        if (a.movedToEight > 0) check("table       " # Nat.toText(a.movedToEight) # " basket(s) of nine moved to rungs 1..8: a part at some genesis neuron fell below one minimum neuron");
        check("table       hash " # hex(hash));
        entries := table;
        dropped := left;
        progress := VarArray.tabulate<T.Progress>(table.size(), func(i) {
          { status = #Pending;
            destination = null; neuron = table[i].firstRung; neuronId = null; takesParent = false;
            lastError = null; attempts = 0; failures = 0 };
        });
        var i = 0;
        while (i < table.size()) {
          let o = table[i].owner;
          let cur = switch (Map.get(ownerIndex, Principal.compare, o)) { case (?v) v; case null [] };
          Map.add(ownerIndex, Principal.compare, o, Array.concat<Nat>(cur, [i]));
          i += 1;
        };
        report := ?{
          closeSeconds;
          cut = switch (cut) { case (?c) c; case null 0 };
          lastFoldedTimestamp = lastFoldedTs;
          tip;
          supplyRebuilt = Int.abs(supplyAll);
          supplyReported;
          stakeRecords = stakesA.size();
          stakesAtClose = existed.size();
          activeStakeTotal = activeTotal;
          saleBalanceAtCut = Int.abs(saleBal);
          genesis;
          fee;
          minimumStake = minStake;
          entries = table.size();
          fullBaskets = nFull;
          smallBaskets = nSmall;
          neurons = nNeurons;
          dropped = left.size();
          droppedWeight;
          dropRounds = a.dropRounds;
          movedToEight = a.movedToEight;
          tableHash = hash;
          checks = List.toArray(checks);
        };
        phase := #Delivering;
        note := "delivering";
        ignore b;
      };
    };
  };

  func Iter_toArray<A>(it : { next : () -> ?A }) : [A] {
    let l = List.empty<A>();
    label l1 loop { switch (it.next()) { case (?x) List.add(l, x); case null break l1 } };
    List.toArray(l);
  };

  func hex(b : Blob) : Text {
    let digits = "0123456789abcdef";
    let d = Text.toArray(digits);
    var out = "";
    for (x in b.values()) {
      let n = Nat8.toNat(x);
      out #= Text.fromChar(d[n / 16]) # Text.fromChar(d[n % 16]);
    };
    out;
  };

  // ── Delivery ────────────────────────────────────────────────────────────────────────

  func setStatus(i : Nat, s : T.Status, nid : ?Blob, err : ?Text) {
    let cur = progress[i];
    if (not L.canMove(cur.neuron, cur.status, cur.neuron, s)) return;
    progress[i] := { cur with status = s; neuronId = switch (nid) { case (?n) ?n; case null cur.neuronId };
                     lastError = err; attempts = cur.attempts + 1 };
  };

  /// The one way back: the step provably did not happen. Returns to Pending on the SAME
  /// neuron and releases what was counted out of the genesis neuron.
  func unwind(i : Nat, k : Nat, amount : Nat, err : Text) {
    takenFrom[k] -= amount;
    parentBusy[k] := null;
    progress[i] := { progress[i] with status = #Pending; neuronId = null; lastError = ?err };
  };

  func advanceAfterStrip(i : Nat) {
    let cur = progress[i];
    if (cur.status != #Granted) return;
    let (k2, s2) = L.afterStrip(cur.neuron, L.lastRung(entries[i]));
    if (not L.canMove(cur.neuron, cur.status, k2, s2)) return;
    progress[i] := { cur with neuron = k2; status = s2; neuronId = if (s2 == #Done) cur.neuronId else null;
                     takesParent = if (s2 == #Done) cur.takesParent else false; lastError = null; attempts = cur.attempts + 1 };
  };

  /// Does any entry other than `i` still have its share in genesis neuron k?
  func othersOwedAt(k : Nat, i : Nat) : Bool {
    var j = 0;
    while (j < entries.size()) {
      if (j != i and L.stillOwedAt(k, entries[j].firstRung, L.lastRung(entries[j]), progress[j].neuron, progress[j].status)) return true;
      j += 1;
    };
    false;
  };

  func balanceOf(b : T.Binding, sub : Blob) : async* Nat {
    await mpvOf(b).icrc1_balance_of({ owner = b.governance; subaccount = ?sub });
  };

  func manage(b : T.Binding, sub : Blob, c : Gov.Command) : async* ?Gov.CommandResponse {
    (await govOf(b).manage_neuron({ subaccount = sub; command = ?c })).command;
  };

  func stepEntry(i : Nat, b : T.Binding, grantable : [Int32]) : async* Result.Result<Text, Text> {
    let p = progress[i];
    if (L.isTerminal(p.status)) return #ok("done");
    switch (L.readiness(p.destination)) {
      case (#AwaitingDestination) return #ok("awaiting a destination from the owner");
      case (#Ready) {};
    };
    await* stepBasket(i, b, grantable);
  };

  func stepBasket(i : Nat, b : T.Binding, grantable : [Int32]) : async* Result.Result<Text, Text> {
    let e = entries[i];
    let k = progress[i].neuron;
    let g = L.partAt(e, k);
    let tag = "neuron " # Nat.toText(k) # ": ";
    let me = self();
    switch (progress[i].status) {

      // 1. Split neuron k off genesis neuron k, or take genesis neuron k itself if this is
      //    the last share it holds.
      case (#Pending) {
        switch (parentBusy[k]) { case (?j) { if (j != i) return #ok(tag # "genesis neuron busy") }; case null {} };
        if (not othersOwedAt(k, i)) {
          let left : Nat = genesis[k] - takenFrom[k];
          if (left != g) return #err(tag # "REFUSING to hand over genesis neuron " # Nat.toText(k) # ": it should hold " # Nat.toText(g) # " for this entry but the books say " # Nat.toText(left));
          handedTo[k] := ?i;
          progress[i] := { progress[i] with takesParent = true };
          setStatus(i, #Split, ?parentId(k), null);
          return #ok(tag # "genesis neuron " # Nat.toText(k) # " itself goes to this holder");
        };
        let seed = switch (memoSeed) { case (?s) s; case null return #err(tag # "no memo seed yet") };
        let memo = memoOf(seed, i, k);
        let child = subaccount(memo);
        // Pending means this canister has never sent a split at this memo: it comes back to
        // Pending only when the split provably did not happen. So a neuron already at this id
        // was made by someone else. It is reported and left alone, and the part moves to its
        // next memo. It is never taken as the part.
        let existing = await govOf(b).get_neuron({ neuron_id = ?{ id = child } });
        switch (existing.result) {
          case (?#Neuron(n)) {
            List.add(foreign, { entry = i; rung = k; neuronId = child; stake = Nat64.toNat(n.cached_neuron_stake_e8s) });
            Map.add(memoStep, Nat.compare, i * L.NEURONS + k, stepOf(i, k) + 1);
            return #ok(tag # "a neuron this canister did not make is at the part's id; the part moves to its next memo");
          };
          case _ {};
        };
        takenFrom[k] += g;
        parentBusy[k] := ?i;
        setStatus(i, #Split, ?child, null);
        try {
          let r = await* manage(b, parentId(k), #Split({ memo; amount_e8s = Nat64.fromNat(g) }));
          switch (r) {
            case (?#Split(s)) {
              switch (s.created_neuron_id) {
                case (?nid) {
                  if (nid.id != child) return #err(tag # "governance created a neuron with an unexpected id");
                  parentBusy[k] := null; splits += 1;
                  #ok(tag # "split off");
                };
                case null #err(tag # "split returned no neuron id");
              };
            };
            // Governance answers Error only when nothing was made (split_neuron removes the
            // child it added if the transfer fails), so this is the one reply that unwinds.
            case (?#Error(gerr)) { unwind(i, k, g, gerr.error_message); #err(tag # "split: " # gerr.error_message) };
            // Any other reply proves nothing either way: the split stays unconfirmed and the
            // next step reads governance (the Split case below).
            case _ #err(tag # "split: unexpected reply; confirming from governance");
          };
        } catch (err) {
          #err(tag # "split rejected: " # Error.message(err));
        };
      };

      // 2. Confirm the neuron if its split is unconfirmed, then GRANT it to the holder.
      case (#Split) {
        let nid = switch (progress[i].neuronId) { case (?n) n; case null return #err(tag # "no neuron id recorded") };
        if (not progress[i].takesParent and parentBusy[k] == ?i) {
          let n = await govOf(b).get_neuron({ neuron_id = ?{ id = nid } });
          switch (n.result) {
            case (?#Neuron(_)) {
              let bal = await* balanceOf(b, nid);
              if (bal + fee < g) return #err(tag # "the split-off neuron does not hold its stake yet");
              parentBusy[k] := null; splits += 1;
            };
            case _ {
              unwind(i, k, g, "the split did not happen; splitting again");
              return #err(tag # "split not made; will split again");
            };
          };
        };
        let dest = switch (progress[i].destination) { case (?d) d; case null return #ok(tag # "awaiting a destination") };
        let r = await* manage(b, nid, #AddNeuronPermissions({ principal_id = ?dest; permissions_to_add = ?{ permissions = grantable } }));
        switch (r) {
          case (?#Error(gerr)) #err(tag # "grant: " # gerr.error_message);
          case (?#AddNeuronPermission(_)) { setStatus(i, #Granted, null, null); #ok(tag # "granted to the holder") };
          case _ #err(tag # "grant: unexpected reply");
        };
      };

      // 3. Strip this canister, then the next neuron. Last on purpose: stopping between
      //    grant and strip leaves a neuron the holder fully controls.
      case (#Granted) {
        let nid = switch (progress[i].neuronId) { case (?n) n; case null return #err(tag # "no neuron id recorded") };
        let cur = await govOf(b).get_neuron({ neuron_id = ?{ id = nid } });
        let mine : [Int32] = switch (cur.result) {
          case (?#Neuron(nn)) L.permissionsOf(nn.permissions, me);
          case _ return #err(tag # "strip: could not read the neuron back");
        };
        if (mine.size() == 0) { advanceAfterStrip(i); return #ok(tag # "already stripped") };
        let r = await* manage(b, nid, #RemoveNeuronPermissions({ principal_id = ?me; permissions_to_remove = ?{ permissions = mine } }));
        switch (r) {
          case (?#Error(gerr)) #err(tag # "strip: " # gerr.error_message);
          case (?#RemoveNeuronPermission(_)) { advanceAfterStrip(i); #ok(tag # "delivered") };
          case _ #err(tag # "strip: unexpected reply");
        };
      };
      case _ #ok("nothing to do");
    };
  };

  /// One step of entry i with the per-entry bookkeeping. Callers hold `driving`.
  func attempt(i : Nat, b : T.Binding, grantable : [Int32]) : async* Result.Result<Text, Text> {
    let r = try { await* stepEntry(i, b, grantable) } catch (err) { #err("rejected: " # Error.message(err)) };
    switch (r) {
      case (#ok(_)) { consecutiveFailures := 0; progress[i] := { progress[i] with failures = 0 } };
      case (#err(m)) {
        consecutiveFailures += 1;
        progress[i] := { progress[i] with failures = progress[i].failures + 1; lastError = ?m };
      };
    };
    r;
  };

  /// What delivery needs from governance each tick: Normal mode (Split is
  /// refused before the swap's finalisation), the same fee and minimum the table was built
  /// with, and the grantable permissions read live (defect F-1).
  func deliveryReady(b : T.Binding) : async* Result.Result<[Int32], Text> {
    let mode = await govOf(b).get_mode({});
    if (mode.mode != ?1) return #err("governance is not in Normal mode yet");
    let p = await govOf(b).get_nervous_system_parameters();
    if (p.transaction_fee_e8s != ?Nat64.fromNat(fee)) return #err("the MPV fee differs from the one the table was built with; waiting");
    if (p.neuron_minimum_stake_e8s != ?Nat64.fromNat(minStake)) return #err("the minimum stake differs from the one the table was built with; waiting");
    switch (p.neuron_grantable_permissions) {
      case (?l) { if (L.grantableIsUsable(l.permissions)) #ok(l.permissions) else #err("governance reports no grantable permissions") };
      case null #err("governance did not report neuron_grantable_permissions");
    };
  };

  /// True if entry i holds its genesis neuron (it is attempted before the scan), or is about
  /// to take from a genesis neuron another entry holds (it waits for that entry).
  func heldOrWaiting(i : Nat) : Bool {
    let p = progress[i];
    switch (parentBusy[p.neuron]) { case (?j) { j == i or p.status == #Pending }; case null false };
  };

  /// Up to `steps` delivery steps: first any entry holding a genesis neuron, then a scan
  /// from the rotating cursor.
  func deliver(b : T.Binding, steps : Nat, paced : Bool) : async* Text {
    let grantable = switch (await* deliveryReady(b)) { case (#ok(g)) g; case (#err(m)) { note := m; return m } };
    if (memoSeed == null) {
      let r = await mgmt().raw_rand();
      if (r.size() != 32) { note := "raw_rand returned " # Nat.toText(r.size()) # " bytes, not 32"; return note };
      memoSeed := ?r;
    };
    let n = entries.size();
    var done = 0;
    var s = 0;
    var last = "nothing actionable: every entry is finished, awaiting its destination, or backing off";
    func actionable(i : Nat) : Bool {
      let p = progress[i];
      not L.isTerminal(p.status) and L.readiness(p.destination) == #Ready
        and (not paced or L.mayAttempt(tick, p.failures));
    };
    // An entry holding a genesis neuron goes first: every other share on that neuron waits
    // for it, so it must never depend on where the rotating cursor happens to stand.
    var k = 0;
    while (k < L.NEURONS and done < steps) {
      switch (parentBusy[k]) {
        case (?j) {
          if (actionable(j)) {
            let r = await* attempt(j, b, grantable);
            last := "entry " # Nat.toText(j) # ": " # (switch (r) { case (#ok(m)) m; case (#err(m)) m });
            done += 1;
          };
        };
        case null {};
      };
      k += 1;
    };
    while (s < n and done < steps) {
      let i = L.scanIndex(cursor, s, n);
      // Holders were attempted above; an entry waiting for one is passed over without
      // using a step.
      if (actionable(i) and not heldOrWaiting(i)) {
        cursor := L.advanceCursor(i, n);
        let r = await* attempt(i, b, grantable);
        last := "entry " # Nat.toText(i) # ": " # (switch (r) { case (#ok(m)) m; case (#err(m)) m });
        done += 1;
        s := 0;
      } else {
        s += 1;
      };
    };
    note := last;
    last;
  };

  func drive(paced : Bool) : async* Text {
    switch (phase, binding) {
      case (#Unbound, _) { await* stepBind(); note };
      case (#AwaitClose, ?b) { await* stepClose(b); note };
      case (#Snapshot, ?b) { await* stepSnapshot(b); note };
      case (#Delivering, ?b) { await* deliver(b, STEPS_PER_TICK, paced) };
      case _ note;
    };
  };

  func guardedDrive(paced : Bool) : async* Text {
    if (driving) return "busy";
    driving := true;
    try {
      await* drive(paced);
    } catch (err) {
      consecutiveFailures += 1;
      note := "rejected: " # Error.message(err);
      note;
    } finally {
      driving := false;
    };
  };

  transient let _ticker = Timer.recurringTimer<system>(#seconds 15, func() : async () {
    tick += 1;
    if (not L.mayAttempt(tick, consecutiveFailures)) return;
    ignore await* guardedDrive(true);
  });

  /// Drives one tick by hand, unpaced, in case the timer is ever wedged. Ingress is
  /// accepted only from principals in the table (see `inspect`).
  public shared func processNext() : async Text { await* guardedDrive(false) };

  // ── Nominating where a basket goes ──────────────────────────────────────────────────
  public shared ({ caller }) func setNeuronDestination(dest : Principal) : async Result.Result<Nat, Text> {
    if (Principal.isAnonymous(caller)) return #err("anonymous cannot nominate");
    let b = switch (binding) { case (?b) b; case null return #err("not bound to the SNS yet") };
    switch (L.destinationRefusal(dest, self(), b.governance, b.ledger)) { case (?e) return #err(e); case null {} };
    let mine = switch (Map.get(ownerIndex, Principal.compare, caller)) { case (?v) v; case null return #err("not in the table") };
    var n = 0;
    for (i in mine.values()) {
      if (L.destinationChangeable(entries[i].firstRung, progress[i].neuron, progress[i].status)) {
        progress[i] := { progress[i] with destination = ?dest };
        n += 1;
      };
    };
    if (n == 0) #err("no basket entry of yours is still open to nomination") else #ok(n);
  };

  // ── P-2: who may send ingress messages ──────────────────────────────────────────────
  system func inspect({ caller : Principal; msg : {
    #processNext : Any; #setNeuronDestination : Any; #reconcile : Any; #settlement : Any;
    #getTable : Any; #getSnapshot : Any; #getProgress : Any; #stats : Any; #myEntries : Any;
    #basketOf : Any; #getBinding : Any; #status : Any; #getEntries : Any; #getDropped : Any;
    #getForeign : Any;
  } }) : Bool {
    switch (msg) {
      case (#processNext _ or #setNeuronDestination _) {
        not Principal.isAnonymous(caller) and Map.get(ownerIndex, Principal.compare, caller) != null;
      };
      // These call other canisters on the caller's behalf: canisters only.
      case (#reconcile _ or #settlement _) false;
      case _ true;
    };
  };

  // ── Read-only surface ───────────────────────────────────────────────────────────────
  public query func getTable() : async [T.Entry] { entries };

  /// A slice of the table, for tables too large for one reply.
  public query func getEntries(from : Nat, count : Nat) : async [T.Entry] {
    if (from >= entries.size()) return [];
    Array.sliceToArray<T.Entry>(entries, from, Nat.min(entries.size(), from + count));
  };

  /// The holders left out of the table (below one minimum neuron), with what they held and
  /// had staked; in principal-text order. Covered by the table hash.
  public query func getDropped() : async [T.Dropped] { dropped };

  public query func getSnapshot() : async ?T.SnapshotReport { report };

  public query func getBinding() : async { binding : ?T.Binding; phase : T.Phase; note : Text } { { binding; phase; note } };

  public query func status() : async { phase : T.Phase; note : Text; snapshotChecks : [Text]; blocksRead : Nat; tip : Nat } {
    { phase; note; snapshotChecks = List.toArray(checks); blocksRead = blockNext; tip };
  };

  public query func getProgress(from : Nat, count : Nat) : async [T.Progress] {
    if (from >= progress.size()) return [];
    Array.tabulate<T.Progress>(Nat.min(count, progress.size() - from), func(j) { progress[from + j] });
  };

  public query ({ caller }) func myEntries() : async [{ index : Nat; entry : T.Entry; progress : T.Progress }] {
    let mine = switch (Map.get(ownerIndex, Principal.compare, caller)) { case (?v) v; case null [] };
    Array.map<Nat, { index : Nat; entry : T.Entry; progress : T.Progress }>(mine, func(i) { { index = i; entry = entries[i]; progress = progress[i] } });
  };

  /// Entry i's basket: each neuron's rung, stake and delay, and whether it is delivered.
  /// A split-off neuron's id is given once its split is sent, and its memo once it is
  /// delivered; before that, neither exists outside this canister.
  public query func basketOf(i : Nat) : async [T.BasketNeuron] {
    if (i >= entries.size()) return [];
    let e = entries[i];
    let p = progress[i];
    let delivered = L.neuronsDelivered(e.firstRung, e.neurons.size(), p.neuron, p.status);
    Array.tabulate<T.BasketNeuron>(e.neurons.size(), func(j) {
      let k = e.firstRung + j;
      let whole = handedTo[k] == ?i;
      let isDelivered = j < delivered;
      let sent = isDelivered or (k == p.neuron and (p.status == #Split or p.status == #Granted));
      let (nid, memo) : (?Blob, ?Nat64) =
        if (whole) { (?parentId(k), ?Nat64.fromNat(k)) }
        else switch (memoSeed) {
          case (?seed) {
            if (sent) { let m = memoOf(seed, i, k); (?subaccount(m), if (isDelivered) ?m else null) } else { (null, null) };
          };
          case null { (null, null) };
        };
      { rung = k;
        neuronId = nid;
        memo;
        genesisNeuron = whole;
        stake = if (whole) e.neurons[j] else e.neurons[j] - fee;
        dissolveDelaySeconds = L.delayOf(k);
        delivered = isDelivered };
    });
  };

  /// Neurons found at a part's id before its split: never made by this canister, outside
  /// the books. Each moved its part to the next memo.
  public query func getForeign() : async [T.Foreign] { List.toArray(foreign) };

  func statsOf() : T.Stats {
    var done = 0; var pending = 0;
    var nFull = 0; var nSmall = 0; var delivered = 0; var total = 0;
    var deliveredStake : Nat = 0;
    var i = 0;
    while (i < entries.size()) {
      let p = progress[i];
      let e = entries[i];
      if (p.status == #Done) done += 1 else pending += 1;
      if (e.neurons.size() == L.NEURONS) nFull += 1 else nSmall += 1;
      total += e.neurons.size();
      let d = L.neuronsDelivered(e.firstRung, e.neurons.size(), p.neuron, p.status);
      delivered += d;
      var j = 0;
      while (j < d) {
        let k = e.firstRung + j;
        deliveredStake += if (handedTo[k] == ?i) e.neurons[j] else e.neurons[j] - fee;
        j += 1;
      };
      i += 1;
    };
    var handed = 0;
    for (h in handedTo.values()) { if (h != null) handed += 1 };
    { phase; entries = entries.size(); done; pending;
      fullBaskets = nFull; smallBaskets = nSmall; dropped = dropped.size();
      neuronsDelivered = delivered; neuronsTotal = total; parentsHandedOver = handed;
      takenFrom = Array.fromVarArray(takenFrom); splits;
      deliveredStake; feesPaid = splits * fee; foreignNeurons = List.size(foreign) };
  };

  public query func stats() : async T.Stats { statsOf() };

  /// The books (INV-R1 restated for neurons, with Q6): every genesis neuron still held has
  /// at least what the table still owes from it; anything above is reported as surplus.
  /// `poolAccounted`: what the holders hold, plus fees, plus what is in flight or still
  /// owed, is the whole pool, to the e8s.
  func reconcileNow() : async* T.Reconciliation {
    let b = switch (binding) { case (?b) b; case null return { parents = []; holds = false; surplus = 0; poolAccounted = false } };
    if (genesis.size() != L.NEURONS) return { parents = []; holds = false; surplus = 0; poolAccounted = false };
    let bals = VarArray.repeat<Nat>(0, L.NEURONS);
    var k = 0;
    while (k < L.NEURONS) {
      if (handedTo[k] == null) bals[k] := await* balanceOf(b, parentId(k));
      k += 1;
    };
    let handed = Array.tabulate<Bool>(L.NEURONS, func(k) { handedTo[k] != null });
    let r = L.reconcile(genesis, Array.fromVarArray(takenFrom), handed, Array.fromVarArray(bals));
    { r with poolAccounted = poolIdentity(r) };
  };

  /// What the entries' statuses say has left the genesis neurons (a basket's part at k
  /// from its split on), plus what each neuron still held owes, must be the whole pool.
  /// Ties the status machine to the books.
  func poolIdentity(r : T.Reconciliation) : Bool {
    var out : Nat = 0;
    var i = 0;
    while (i < entries.size()) {
      let p = progress[i];
      let e = entries[i];
      var j = 0;
      while (j < e.neurons.size()) {
        let k = e.firstRung + j;
        let left = p.status == #Done or k < p.neuron or (k == p.neuron and (p.status == #Split or p.status == #Granted));
        if (left) out += e.neurons[j];
        j += 1;
      };
      i += 1;
    };
    var held : Nat = 0;
    for (pb in r.parents.values()) { if (not pb.handedOver) held += pb.expected };
    out + held == L.POOL_E8S;
  };

  public shared func reconcile() : async T.Reconciliation { await* reconcileNow() };

  public shared func settlement() : async T.Settlement {
    let s = statsOf();
    let r = await* reconcileNow();
    let ok = L.settled(s, r) and r.poolAccounted;
    {
      settled = ok;
      dropped = s.dropped;
      neuronsDelivered = s.neuronsDelivered;
      neuronsTotal = s.neuronsTotal;
      reason = switch (phase) {
        case (#Unbound or #AwaitClose or #Snapshot) "the snapshot has not been taken yet";
        case (#Aborted) "the swap was aborted; there is nothing to deliver";
        case (#Halted(why)) "halted: " # why;
        case (#Delivering) {
          if (ok) {
            "every share delivered; every genesis neuron handed over; books hold"
            # (if (r.surplus > 0) "; surplus " # Nat.toText(r.surplus) # " e8s (donated)" else "")
          } else if (s.done != s.entries) {
            Nat.toText(s.entries - s.done) # " entr(ies) still to deliver" # stalledNote()
          } else if (not r.holds) "a genesis neuron holds less than the table still owes from it"
          else if (not r.poolAccounted) "the books do not account for the whole pool"
          else Nat.toText(L.NEURONS - s.parentsHandedOver) # " genesis neuron(s) not yet handed over";
        };
      };
    };
  };

  func stalledNote() : Text {
    let failures = Array.tabulate<Nat>(entries.size(), func(i) { progress[i].failures });
    let terminal = Array.tabulate<Bool>(entries.size(), func(i) { L.isTerminal(progress[i].status) });
    switch (L.mostFailed(failures, terminal)) {
      case null "";
      case (?i) {
        "; entry " # Nat.toText(i) # " has failed " # Nat.toText(progress[i].failures) # " consecutive attempt(s)"
        # (switch (progress[i].lastError) { case (?e) ": " # e; case null "" });
      };
    };
  };
}

/// Logic.mo: the PURE decision core of the holder canister.
///
/// Every function here is referentially transparent (no awaits, no state, no I/O), so the
/// whole battery runs under the interpreter with no replica. Redemption.mo calls these for
/// the table, the arithmetic and the gating; the tests drive the same functions.

import T "Types";
import I "Ifaces";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import List "mo:core/List";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Order "mo:core/Order";
import Sha256 "mo:sha2/Sha256";

module {

  // ── Fixed by the MPV sns_init.yaml, compiled in ────────────────────────────────────

  /// Neurons per basket and per genesis set: the swap's own nine.
  public let NEURONS : Nat = 9;
  /// 182 days between dissolve delays, the swap's interval. Genesis neuron k has k x this.
  public let INTERVAL_SECONDS : Nat64 = 15_724_800;
  /// The 15,000,000 MPV the genesis neurons must add up to.
  public let POOL_E8S : Nat = 1_500_000_000_000_000;
  /// Stake records are read 0, 1, 2, ... until this many ids in a row are missing.
  public let STAKE_MISSES_TO_STOP : Nat = 64;

  // ── The table rule (identical to build-table's `split`) ─────────────────────────────

  /// Largest remainder: `total` shared by `weights` so the parts add up to exactly `total`
  /// and each is within one e8s of its exact share. The extra units go to the largest
  /// remainders; ties go to the lower index, and the caller orders by principal text, so
  /// ties go to the lower principal text exactly as build-table does.
  public func largestRemainder(total : Nat, weights : [Nat]) : [Nat] {
    let n = weights.size();
    var w : Nat = 0;
    for (x in weights.values()) { w += x };
    if (w == 0) return Array.tabulate<Nat>(n, func(_) { 0 });
    let base = VarArray.tabulate<Nat>(n, func(i) { total * weights[i] / w });
    var given : Nat = 0;
    for (b in base.values()) { given += b };
    let rest : Nat = total - given;
    if (rest > 0) {
      let order = Array.sort<Nat>(Array.tabulate<Nat>(n, func(i) { i }), func(a, b) {
        let ra = (total * weights[a]) % w;
        let rb = (total * weights[b]) % w;
        if (ra > rb) #less else if (ra < rb) #greater else Nat.compare(a, b);
      });
      var j = 0;
      while (j < rest) { base[order[j]] += 1; j += 1 };
    };
    Array.fromVarArray(base);
  };

  /// One minimum neuron: the minimum stake plus the fee a Split charges the parent.
  public func unit(fee : Nat, minStake : Nat) : Nat { minStake + fee };

  /// Neurons in a basket: min(9, floor(gross / (minimum + fee))).
  public func neuronCount(gross : Nat, fee : Nat, minStake : Nat) : Nat {
    Nat.min(NEURONS, gross / unit(fee, minStake));
  };

  /// A basket of n < 9 neurons: rungs 1..n, the gross share in equal parts, the remainder
  /// on the last part. Every part is at least one minimum neuron because gross >= n x unit.
  public func smallParts(gross : Nat, n : Nat) : [Nat] {
    let q = gross / n;
    Array.tabulate<Nat>(n, func(j) { if (j + 1 == n) gross - q * (n - 1) else q });
  };

  public type Allocation = {
    /// Indices into the input of the holders in the table, in input order.
    kept : [Nat];
    /// Indices of the holders left out, in input order.
    dropped : [Nat];
    /// Per kept holder: the gross share among the kept holders.
    gross : [Nat];
    /// Per kept holder: 0 for a basket of nine, 1 for a smaller basket.
    firstRung : [Nat];
    /// Per kept holder: the parts, rung firstRung + j for part j.
    neurons : [[Nat]];
    /// Rounds of the redistribution, including the last, which changed nothing.
    dropRounds : Nat;
    /// Baskets of nine moved to rungs 1..8 because a part fell below one minimum neuron.
    movedToEight : Nat;
  };

  /// The whole allocation, from the weights (in principal-text order) and the genesis
  /// stakes. `#err` if nobody reaches one minimum neuron, or no basket of nine remains to
  /// take genesis neuron 0.
  ///
  ///   1. S_0 = every holder. gross over S_i = largest remainder of the pool by weight over
  ///      S_i; S_{i+1} = the holders of S_i whose gross is at least minimum + fee. Repeat
  ///      until S_{i+1} = S_i. A holder left out is never added back.
  ///   2. n = min(9, floor(gross / (minimum + fee))) for every holder kept.
  ///   3. n < 9: parts at rungs 1..n, the gross in equal parts, remainder on the last.
  ///   4. n = 9: the part at rung k = largest remainder of P_k over the baskets of nine by
  ///      weight, P_k = stake_k less the smaller baskets' parts at k. So every genesis
  ///      neuron is shared out to the e8s, and nothing is left in it.
  ///   5. A basket of nine with a part below minimum + fee is moved to rungs 1..8 (its gross
  ///      in eight equal parts, each above the minimum); then 4 again. Only ever moves
  ///      baskets out of the nine, so it ends.
  public func allocate(weights : [Nat], stakes : [Nat], fee : Nat, minStake : Nat) : { #ok : Allocation; #err : Text } {
    let n = weights.size();
    if (stakes.size() != NEURONS) return #err("expected " # Nat.toText(NEURONS) # " genesis stakes");
    let u = unit(fee, minStake);
    var pool : Nat = 0;
    for (st in stakes.values()) { pool += st };

    // 1. The redistribution, iterated.
    var set : [Nat] = Array.tabulate<Nat>(n, func(i) { i });
    var gross : [Nat] = [];
    var rounds = 0;
    label redistribute loop {
      if (set.size() == 0) return #err("no holder's share reaches one minimum neuron");
      gross := largestRemainder(pool, Array.map<Nat, Nat>(set, func(i) { weights[i] }));
      rounds += 1;
      let keep = List.empty<Nat>();
      var j = 0;
      while (j < set.size()) { if (gross[j] >= u) List.add(keep, set[j]); j += 1 };
      if (List.size(keep) == set.size()) break redistribute;
      set := List.toArray(keep);
    };
    let kept = set;
    let m = kept.size();
    let isKept = VarArray.repeat<Bool>(false, n);
    for (i in kept.values()) { isKept[i] := true };
    let dropped = Array.filter<Nat>(Array.tabulate<Nat>(n, func(i) { i }), func(i) { not isKept[i] });

    // 2-5. Neuron counts and parts.
    let count = VarArray.tabulate<Nat>(m, func(j) { neuronCount(gross[j], fee, minStake) });
    var moved = 0;
    var guard = 0;
    while (guard <= m) {
      let small = VarArray.repeat<Nat>(0, NEURONS);
      let fullIdx = List.empty<Nat>();
      var j = 0;
      while (j < m) {
        if (count[j] == NEURONS) List.add(fullIdx, j) else {
          let parts = smallParts(gross[j], count[j]);
          var r = 0;
          while (r < parts.size()) { small[1 + r] += parts[r]; r += 1 };
        };
        j += 1;
      };
      let full = List.toArray(fullIdx);
      if (full.size() == 0) return #err("no holder's share fills nine neurons, so genesis neuron 0 could not be delivered");
      var k = 0;
      while (k < NEURONS) {
        if (small[k] > stakes[k]) return #err("the smaller baskets need more than genesis neuron " # Nat.toText(k) # " holds");
        k += 1;
      };
      let fWeights = Array.map<Nat, Nat>(full, func(j2) { weights[kept[j2]] });
      let perK = Array.tabulate<[Nat]>(NEURONS, func(k2) { largestRemainder(stakes[k2] - small[k2], fWeights) });
      var anyMoved = false;
      var f = 0;
      while (f < full.size()) {
        var short = false;
        var k3 = 0;
        while (k3 < NEURONS) { if (perK[k3][f] < u) short := true; k3 += 1 };
        if (short) { count[full[f]] := NEURONS - 1; anyMoved := true; moved += 1 };
        f += 1;
      };
      if (not anyMoved) {
        let parts = VarArray.repeat<[Nat]>([], m);
        var c = 0;
        while (c < full.size()) {
          parts[full[c]] := Array.tabulate<Nat>(NEURONS, func(k4) { perK[k4][c] });
          c += 1;
        };
        var d = 0;
        while (d < m) { if (count[d] < NEURONS) parts[d] := smallParts(gross[d], count[d]); d += 1 };
        return #ok({
          kept; dropped; gross;
          firstRung = Array.tabulate<Nat>(m, func(x) { if (count[x] == NEURONS) 0 else 1 });
          neurons = Array.fromVarArray(parts);
          dropRounds = rounds; movedToEight = moved;
        });
      };
      guard += 1;
    };
    #err("moving baskets of nine to rungs 1..8 did not end");
  };

  // ── The canonical table (byte-identical to build-table's table_bytes) ─────────────

  func u64be(x : Nat) : [Nat8] {
    Array.tabulate<Nat8>(8, func(i) { Nat8.fromNat((x / (256 ** (7 - i))) % 256) });
  };

  func u32be(x : Nat) : [Nat8] {
    Array.tabulate<Nat8>(4, func(i) { Nat8.fromNat((x / (256 ** (3 - i))) % 256) });
  };

  /// "MPV-HOLDER-TABLE-v2" | fee u64 | minimum u64 | 9 u8 | stakes 9 x u64 |
  /// rows u32 | per row: principal length u8, principal bytes, held u64, staked u64,
  /// gross u64, first rung u8, neuron count u8, each part u64 |
  /// dropped u32 | per dropped holder: principal length u8, principal bytes, held u64,
  /// staked u64. All big-endian. SHA-256 of this is the published table hash, so the hash
  /// covers the dropped list too.
  public func tableBytes(entries : [T.Entry], dropped : [T.Dropped], fee : Nat, minStake : Nat, stakes : [Nat]) : Blob {
    let out = List.empty<Nat8>();
    func put(bytes : [Nat8]) { for (x in bytes.values()) List.add(out, x) };
    func who(p : Principal) { let pb = Blob.toArray(Principal.toBlob(p)); put([Nat8.fromNat(pb.size())]); put(pb) };
    put(Blob.toArray(Text.encodeUtf8("MPV-HOLDER-TABLE-v2")));
    put(u64be(fee));
    put(u64be(minStake));
    put([Nat8.fromNat(stakes.size())]);
    for (st in stakes.values()) put(u64be(st));
    put(u32be(entries.size()));
    for (e in entries.values()) {
      who(e.owner);
      put(u64be(e.held));
      put(u64be(e.staked));
      put(u64be(e.gross));
      put([Nat8.fromNat(e.firstRung), Nat8.fromNat(e.neurons.size())]);
      for (g in e.neurons.values()) put(u64be(g));
    };
    put(u32be(dropped.size()));
    for (d in dropped.values()) { who(d.owner); put(u64be(d.held)); put(u64be(d.staked)) };
    Blob.fromArray(List.toArray(out));
  };

  /// Principal-text order, the order of the table and of every tie-break.
  public func byText(a : Principal, b : Principal) : Order.Order {
    Text.compare(Principal.toText(a), Principal.toText(b));
  };

  // ── Folding the MENES ledger ────────────────────────────────────────────────────────

  public type Effect = {
    /// (owner, signed change); subaccounts fold into the owner.
    deltas : [(Principal, Int)];
    /// Change of the total supply (mints in, burns and fees out).
    supply : Int;
  };

  /// What one block does to balances. The same rule as build-table's `fold`: a transfer's
  /// fee leaves the sender and the supply; an approval costs its fee.
  public func effectOf(t : I.Transaction) : { #ok : Effect; #err : Text } {
    func feeOf(f : ?Nat) : Nat { switch (f) { case (?x) x; case null 0 } };
    switch (t.kind, t.mint, t.burn, t.transfer, t.approve) {
      case ("mint", ?m, _, _, _) #ok({ deltas = [(m.to.owner, m.amount)]; supply = m.amount });
      case ("burn", _, ?b, _, _) #ok({ deltas = [(b.from.owner, -b.amount)]; supply = -b.amount });
      case ("transfer", _, _, ?x, _) {
        let f = feeOf(x.fee);
        #ok({ deltas = [(x.from.owner, -(x.amount + f)), (x.to.owner, x.amount)]; supply = -f });
      };
      case ("approve", _, _, _, ?a) {
        let f = feeOf(a.fee);
        #ok({ deltas = [(a.from.owner, -f)]; supply = -f });
      };
      case (k, _, _, _, _) #err("unknown or malformed block kind \"" # k # "\"");
    };
  };

  /// A block is folded if its timestamp is at or before the close.
  public func beforeClose(timestampNs : Nat64, closeSeconds : Nat64) : Bool {
    Nat64.toNat(timestampNs) <= Nat64.toNat(closeSeconds) * 1_000_000_000;
  };

  /// The blocks a get_transactions reply and its archive callbacks gave for a request
  /// starting at `start`, as one contiguous run from `start`. Each piece is (first index,
  /// blocks). Returns how many blocks from `start` are covered without a gap.
  public func contiguousFrom(start : Nat, pieces : [(Nat, Nat)]) : Nat {
    var at = start;
    var progress = true;
    while (progress) {
      progress := false;
      for ((first, len) in pieces.values()) {
        if (len > 0 and first <= at and at < first + len) { at := first + len; progress := true };
      };
    };
    at - start;
  };

  // ── Stakes at the close ─────────────────────────────────────────────────────────────

  /// A stake existed at the close if it was made at or before it.
  public func existedAtClose(s : T.StakeInfo, closeSeconds : Nat64) : Bool {
    s.stakedAt <= Nat64.toNat(closeSeconds) * 1_000_000_000;
  };

  /// The sale canister keeps no record of WHEN a stake was withdrawn. Both of its
  /// withdrawal paths pay at least the stake's principal to the owner in ONE transfer. So
  /// an inactive stake that existed at the close was already inactive then, unless some
  /// transfer after the cut from the sale canister to its owner is at least its amount.
  /// Any such transfer: the stake's state at the close cannot be known, and the snapshot
  /// must stop. Returns the first unresolvable (stake id, block index), if any.
  public func unresolvedWithdrawal(
    inactive : [T.StakeInfo],
    saleTransfersAfterCut : [(Nat, Principal, Nat)],
  ) : ?(Nat, Nat) {
    for ((index, to, amount) in saleTransfersAfterCut.values()) {
      for (s in inactive.values()) {
        if (Principal.equal(s.owner, to) and amount >= s.amount) return ?(s.id, index);
      };
    };
    null;
  };

  /// Two reads of the stakes agree on everything the snapshot uses.
  public func sameStakes(a : [T.StakeInfo], b : [T.StakeInfo]) : Bool {
    if (a.size() != b.size()) return false;
    var i = 0;
    while (i < a.size()) {
      let x = a[i];
      let y = b[i];
      if (x.id != y.id or not Principal.equal(x.owner, y.owner) or x.amount != y.amount
          or x.active != y.active or x.stakedAt != y.stakedAt) return false;
      i += 1;
    };
    true;
  };

  // ── Exclusions ──────────────────────────────────────────────────────────────────────

  public func contains(list : [Text], p : Principal) : Bool {
    let t = Principal.toText(p);
    for (x in list.values()) { if (x == t) return true };
    false;
  };

  // ── Neuron ids and memos ────────────────────────────────────────────────────────────

  /// The memo of entry i's neuron at rung k, attempt `step`: the first eight bytes of
  ///
  ///     sha256( [21] ++ b"menese-mpv-split-memo" ++ [len] ++ seed ++ entry_be ++ k_be ++ step_be )
  ///
  /// read big-endian, with the top bit set so that it is never a genesis memo 0..8. The seed
  /// is drawn once by the canister from the IC's randomness and never leaves it, so nobody
  /// else can compute a memo, and nobody can claim a neuron at a basket's id before the
  /// canister splits it there. `step` moves a part to a fresh memo if its id is ever found
  /// occupied.
  public func splitMemo(seed : Blob, entry : Nat, k : Nat, step : Nat) : Nat64 {
    let pre = List.empty<Nat8>();
    let domain = Blob.toArray("menese-mpv-split-memo");
    List.add(pre, Nat8.fromNat(domain.size()));
    for (c in domain.values()) List.add(pre, c);
    let s = Blob.toArray(seed);
    List.add(pre, Nat8.fromNat(s.size()));
    for (c in s.values()) List.add(pre, c);
    for (x in [entry, k, step].values()) {
      let v = Nat64.fromNat(x);
      var b : Nat = 0;
      while (b < 8) { List.add(pre, Nat8.fromNat(Nat64.toNat((v >> Nat64.fromNat((7 - b) * 8)) & 0xFF))); b += 1 };
    };
    let h = Blob.toArray(Sha256.fromBlob(#sha256, Blob.fromArray(List.toArray(pre))));
    var m : Nat64 = 0;
    var b : Nat = 0;
    while (b < 8) { m := (m << 8) | Nat64.fromNat(Nat8.toNat(h[b])); b += 1 };
    m | 0x8000_0000_0000_0000;
  };

  /// The dissolve delay of genesis neuron k, and so of every neuron delivered at k.
  public func delayOf(k : Nat) : Nat64 { INTERVAL_SECONDS * Nat64.fromNat(k) };

  /// The preimage of the SNS staking subaccount, byte-for-byte as the IC computes it in
  /// rs/nervous_system/common/src/ledger.rs:
  ///
  ///     sha256( [12] ++ b"neuron-stake" ++ controller.as_slice() ++ memo_be )
  ///
  /// A neuron's id IS this subaccount. The caller applies SHA-256.
  public func stakingSubaccountPreimage(controller : Principal, nonce : Nat64) : Blob {
    let domain : [Nat8] = [0x6e, 0x65, 0x75, 0x72, 0x6f, 0x6e, 0x2d, 0x73, 0x74, 0x61, 0x6b, 0x65]; // "neuron-stake"
    let pbytes = Blob.toArray(Principal.toBlob(controller));
    let total = 1 + domain.size() + pbytes.size() + 8;
    let out = VarArray.repeat<Nat8>(0, total);
    out[0] := Nat8.fromNat(domain.size());
    var i = 0;
    while (i < domain.size()) { out[1 + i] := domain[i]; i += 1 };
    var j = 0;
    while (j < pbytes.size()) { out[1 + domain.size() + j] := pbytes[j]; j += 1 };
    let base = 1 + domain.size() + pbytes.size();
    var k : Nat = 0;
    while (k < 8) {
      let shift : Nat64 = Nat64.fromNat((7 - k) * 8);
      out[base + k] := Nat8.fromNat(Nat64.toNat((nonce >> shift) & 0xFF));
      k += 1;
    };
    Array.fromVarArray(out) |> Blob.fromArray(_);
  };

  // ── The delivery state machine (INV-R2: forward only) ───────────────────────────────

  public func rank(s : T.Status) : Nat {
    switch (s) {
      case (#Pending) 0;
      case (#Split) 1;
      case (#Granted) 2;
      case (#Done) 3;
    };
  };

  public func isTerminal(s : T.Status) : Bool { s == #Done };

  /// The last rung of an entry's basket.
  public func lastRung(e : T.Entry) : Nat { e.firstRung + e.neurons.size() - 1 };

  /// The entry's part at rung k (k within its rungs).
  public func partAt(e : T.Entry, k : Nat) : Nat { e.neurons[k - e.firstRung] };

  /// The (rung, status) pair only moves forward, and nothing leaves Done. The rung changes
  /// in one way only: the strip of rung k, (k, Granted), moves to (k+1, Pending). Releasing
  /// a step that provably did not happen is the one exception, and it is a separate path
  /// (`unwind` in the actor), never through here.
  public func canMove(fromK : Nat, from : T.Status, toK : Nat, to : T.Status) : Bool {
    if (isTerminal(from)) return false;
    if (toK != fromK) return toK == fromK + 1 and from == #Granted and to == #Pending;
    rank(to) > rank(from);
  };

  /// After the strip of rung k: the next rung, or Done after the last one.
  public func afterStrip(k : Nat, last : Nat) : (Nat, T.Status) {
    if (k < last) (k + 1, #Pending) else (k, #Done);
  };

  /// Neurons of the basket delivered so far.
  public func neuronsDelivered(first : Nat, count : Nat, k : Nat, s : T.Status) : Nat {
    if (s == #Done) count else k - first;
  };

  /// Has an entry's share at genesis neuron k NOT yet left that neuron? It leaves at the
  /// split (status Split at k, or any later rung). A share in flight (Split not yet
  /// confirmed) counts as gone: the caller only asks when genesis neuron k has nothing in
  /// flight. An entry with no part at k owes nothing there.
  public func stillOwedAt(k : Nat, first : Nat, last : Nat, neuron : Nat, s : T.Status) : Bool {
    if (s == #Done or k < first or k > last) return false;
    neuron < k or (neuron == k and s == #Pending);
  };

  // ── Owner-nominated destinations ────────────────────────────────────────────────────

  public type Ready = { #Ready; #AwaitingDestination };

  /// A basket waits until its owner nominates a destination. There is no fallback: waiting
  /// is not failing, nothing expires, and it does not block the entries behind it.
  public func readiness(destination : ?Principal) : Ready {
    switch (destination) { case null #AwaitingDestination; case (?_) #Ready };
  };

  /// A destination is refused if nobody could ever control a neuron granted to it.
  /// Granting to this canister is the dangerous one: the strip that follows would leave
  /// the neuron with no controller at all.
  public func destinationRefusal(dest : Principal, self : Principal, governance : Principal, ledger : Principal) : ?Text {
    if (Principal.isAnonymous(dest)) return ?"destination cannot be anonymous";
    if (Principal.equal(dest, self)) return ?"destination cannot be this canister: the strip would leave the neuron controlled by nobody";
    if (Principal.equal(dest, governance)) return ?"destination cannot be the governance canister";
    if (Principal.equal(dest, ledger)) return ?"destination cannot be the ledger canister";
    if (Principal.toText(dest) == "aaaaa-aa") return ?"destination cannot be the management canister";
    null;
  };

  /// Changeable until the basket's first neuron has started, then frozen, so every neuron
  /// of a basket goes to the same principal.
  public func destinationChangeable(first : Nat, k : Nat, s : T.Status) : Bool { k == first and s == #Pending };

  // ── Neuron permissions ──────────────────────────────────────────────────────────────

  /// The permissions `who` holds on a neuron, as governance reports them. Empty if `who`
  /// appears nowhere: the "already stripped" case.
  public func permissionsOf(perms : [{ principal : ?Principal; permission_type : [Int32] }], who : Principal) : [Int32] {
    var found : [Int32] = [];
    for (p in perms.values()) {
      switch (p.principal) {
        case (?owner) { if (Principal.equal(owner, who)) found := p.permission_type };
        case null {};
      };
    };
    found;
  };

  public func grantableIsUsable(permissions : [Int32]) : Bool { permissions.size() > 0 };

  // ── Binding after genesis ───────────────────────────────────────────────────────────

  /// The canister binds only once SNS root is its SOLE controller: that happens when the
  /// swap commits and the swap canister hands the dapps to the DAO.
  public func soleController(controllers : [Principal]) : ?Principal {
    if (controllers.size() == 1) ?controllers[0] else null;
  };

  /// The SNS that `controller` describes, if it names itself as root and this canister
  /// among its dapps, and gives governance, ledger and swap.
  public func bindingFrom(controller : Principal, a : I.ListSnsCanistersResponse, self : Principal, now : Int) : ?T.Binding {
    switch (a.root, a.governance, a.ledger, a.swap) {
      case (?root, ?governance, ?ledger, ?swap) {
        if (not Principal.equal(root, controller)) return null;
        if (Array.find<Principal>(a.dapps, func(d) { Principal.equal(d, self) }) == null) return null;
        ?{ root; governance; ledger; swap; boundAt = now };
      };
      case _ null;
    };
  };

  /// Does NNS SNS-W list exactly this SNS (same root, governance, ledger and swap) as one it
  /// deployed? A controller answering list_sns_canisters is not enough alone: whoever
  /// controls this canister before it is handed to the NNS could add one that answers.
  public func deployedByNns(b : T.Binding, instances : [I.DeployedSns]) : Bool {
    for (i in instances.values()) {
      switch (i.root_canister_id, i.governance_canister_id, i.ledger_canister_id, i.swap_canister_id) {
        case (?r, ?g, ?l, ?s) {
          if (Principal.equal(r, b.root) and Principal.equal(g, b.governance)
              and Principal.equal(l, b.ledger) and Principal.equal(s, b.swap)) return true;
        };
        case _ {};
      };
    };
    false;
  };

  // ── Genesis neurons ─────────────────────────────────────────────────────────────────

  /// Genesis neuron k as the canister needs it: this canister holds permissions on it, its
  /// delay is k x 182 days, it is not vesting, and it has no fees. Returns the reason if not.
  public func genesisRefusal(k : Nat, n : { cached_neuron_stake_e8s : Nat64; neuron_fees_e8s : Nat64;
                                           vesting_period_seconds : ?Nat64; created_timestamp_seconds : Nat64;
                                           dissolve_state : ?{ #DissolveDelaySeconds : Nat64; #WhenDissolvedTimestampSeconds : Nat64 };
                                           permissions : [{ principal : ?Principal; permission_type : [Int32] }] },
                              self : Principal, nowSeconds : Nat64) : ?Text {
    let tag = "genesis neuron " # Nat.toText(k) # ": ";
    if (permissionsOf(n.permissions, self).size() == 0) return ?(tag # "this canister holds no permission on it");
    switch (n.dissolve_state) {
      case (?#DissolveDelaySeconds(d)) { if (d != delayOf(k)) return ?(tag # "dissolve delay " # Nat64.toText(d) # " s, expected " # Nat64.toText(delayOf(k))) };
      case _ return ?(tag # "not a fixed dissolve delay");
    };
    if (n.neuron_fees_e8s != 0) return ?(tag # "has neuron fees");
    switch (n.vesting_period_seconds) {
      case (?v) { if (n.created_timestamp_seconds + v >= nowSeconds) return ?(tag # "still vesting") };
      case null {};
    };
    if (n.cached_neuron_stake_e8s == 0) return ?(tag # "has no stake");
    null;
  };

  // ── Driver backoff and fairness ─────────────────────────────────────────────────────

  /// Ticks to skip given consecutive failures: exponential, capped at 240 ticks.
  public func backoffTicks(consecutiveFailures : Nat) : Nat {
    if (consecutiveFailures == 0) return 1;
    var b = 1;
    var n = consecutiveFailures;
    while (n > 0 and b < 240) { b *= 2; n -= 1 };
    if (b > 240) 240 else b;
  };

  public func mayAttempt(tick : Nat, consecutiveFailures : Nat) : Bool {
    tick % backoffTicks(consecutiveFailures) == 0;
  };

  /// The driver scans from a rotating cursor, so one entry that keeps failing cannot stop
  /// every entry behind it from being attempted.
  public func scanIndex(cursor : Nat, step : Nat, size : Nat) : Nat {
    if (size == 0) 0 else (cursor + step) % size;
  };

  public func advanceCursor(i : Nat, size : Nat) : Nat {
    if (size == 0) 0 else (i + 1) % size;
  };

  public func mostFailed(failures : [Nat], terminal : [Bool]) : ?Nat {
    var i = 0;
    var best : ?Nat = null;
    var bestFailures = 0;
    while (i < failures.size() and i < terminal.size()) {
      if (not terminal[i] and failures[i] > bestFailures) { best := ?i; bestFailures := failures[i] };
      i += 1;
    };
    best;
  };

  // ── The books (INV-R1 for neurons; Q6) ──────────────────────────────────────────────

  /// For each genesis neuron still held: its staking subaccount's balance against what the
  /// table still owes from it. `holds` if every one has at least that; anything above it is
  /// reported as surplus (a donation), never treated as a mismatch.
  public func reconcile(stakes : [Nat], takenFrom : [Nat], handedOver : [Bool], balances : [Nat]) : T.Reconciliation {
    var holds = true;
    var surplus : Nat = 0;
    let parents = Array.tabulate<T.ParentBooks>(stakes.size(), func(k) {
      let expected : Nat = if (handedOver[k] or takenFrom[k] >= stakes[k]) 0 else stakes[k] - takenFrom[k];
      { index = k; expected; balance = balances[k]; handedOver = handedOver[k] };
    });
    for (p in parents.values()) {
      if (not p.handedOver) {
        if (p.balance < p.expected) holds := false else surplus += p.balance - p.expected;
      };
    };
    { parents; holds; surplus; poolAccounted = true };
  };

  /// Settled: every entry delivered, every genesis neuron handed over, and the books hold.
  public func settled(s : T.Stats, r : T.Reconciliation) : Bool {
    s.done == s.entries and s.parentsHandedOver == NEURONS and r.holds;
  };
}

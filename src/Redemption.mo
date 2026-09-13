/// Redemption.mo: the actor.
///
/// Pays every entry in a table fixed at initialisation and never mutable afterwards.
/// Wallet holders receive liquid tokens; stakers receive a neuron they control outright.
/// It pushes on a timer, so nobody has to know to claim.
///
/// The three properties worth stating up front, because they are what an auditor checks:
///
///   1. There is NO admin. Not a locked-down admin, none at all. No method adds, edits or
///      removes an entry, changes a destination, or moves the reserve anywhere but to an
///      entry's own payout.
///   2. There is NO mint authority. It can only ever pay out what it was given.
///   3. Status is written BEFORE the call it guards, never after. A Motoko `await` is a
///      commit point, so marking after a transfer is a double-spend.
///
/// Design: docs/DESIGN.md

import Principal "mo:core/Principal";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import Text "mo:core/Text";
import List "mo:core/List";
import Timer "mo:core/Timer";
import Result "mo:core/Result";
import Time "mo:core/Time";
import Int "mo:core/Int";
import Error "mo:core/Error";
import Sha256 "mo:sha2/Sha256";

import T "Types";
import L "Logic";
import ICRC "ICRC";
import Gov "SnsGov";

persistent actor class Redemption(init : {
  /// The new SNS token ledger.
  ledger : Principal;
  /// The SNS governance canister.
  governance : Principal;
  /// The eligible set, frozen at the snapshot block. Published alongside the module hash.
  entries : [T.Entry];
  /// What treasury transfers in. Recorded so INV-R1 has a left-hand side.
  initialReserve : Nat;
  /// The ledger's transfer fee, in e8s.
  fee : Nat;
}) = this {

  // ── Immutable state ─────────────────────────────────────────────────────────────────
  // `stable let`: written once at initialisation, and there is no method that can change
  // any of it. The eligible set is fixed by the code, not by a guard on a setter.
  let entries : [T.Entry] = init.entries;
  let ledgerId : Principal = init.ledger;
  let governanceId : Principal = init.governance;
  let initialReserve : Nat = init.initialReserve;
  let feeE8s : Nat = init.fee;

  // ── Mutable state: progress only ────────────────────────────────────────────────────
  let progress : [var T.Progress] =
    VarArray.repeat<T.Progress>({ status = #Pending; destination = null; neuronId = null; lastError = null; attempts = 0; failures = 0; txTime = null }, entries.size());
  var feesPaid : Nat = 0;
  var paidOut : Nat = 0;
  var checked : Bool = false;
  /// Consecutive failed attempts across the whole driver, for the backoff (audit R-1). Reset
  /// to zero by any success, so recovery is automatic and needs no operator.
  var consecutiveFailures : Nat = 0;
  /// Timer ticks since install. Only the backoff reads it.
  var tick : Nat = 0;
  /// Where the driver's next scan begins. Rotating, so no entry can monopolise the driver.
  var cursor : Nat = 0;

  transient let ledger : ICRC.Ledger = actor (Principal.toText(ledgerId));
  transient let gov : Gov.Service = actor (Principal.toText(governanceId));
  transient let busy : [var Bool] = VarArray.repeat<Bool>(false, entries.size());

  // ── Init-time assertion (INV-R5) ────────────────────────────────────────────────────
  //
  // Every delay in the table was computed against DISSOLVE_FLOOR_SECONDS. If the live
  // parameter is higher than that, every neuron issued would be silently unable to vote.
  // This refuses to start rather than producing voteless neurons, and it is checked against
  // the network rather than against a second local constant.
  public shared func verifyParameters() : async Result.Result<Text, Text> {
    let p = await gov.get_nervous_system_parameters();
    switch (p.neuron_minimum_dissolve_delay_to_vote_seconds) {
      case null { #err("governance did not report a voting floor") };
      case (?live) {
        if (L.DISSOLVE_FLOOR_SECONDS < live) {
          #err("REFUSING TO RUN: configured floor " # Nat64.toText(L.DISSOLVE_FLOOR_SECONDS)
               # "s is below the live voting floor " # Nat64.toText(live)
               # "s; every neuron issued would be unable to vote");
        } else {
          checked := true;
          #ok("floor ok: configured " # Nat64.toText(L.DISSOLVE_FLOOR_SECONDS)
              # "s >= live " # Nat64.toText(live) # "s");
        };
      };
    };
  };

  // ── Helpers ─────────────────────────────────────────────────────────────────────────

  func setStatus(i : Nat, s : T.Status, nid : ?Blob, err : ?Text) {
    let cur = progress[i];
    // INV-R2 enforced here and nowhere else: forward only, never out of a terminal state.
    if (not L.canAdvance(cur.status, s)) return;
    progress[i] := {
      status = s;
      destination = cur.destination;
      neuronId = switch (nid) { case (?n) ?n; case null cur.neuronId };
      lastError = err;
      attempts = cur.attempts + 1;
      failures = cur.failures;
      txTime = cur.txTime;
    };
  };

  /// Deliberately outside `canAdvance` (audit R-1/R-3): the ONLY way back out of an advanced
  /// status, used when the call that the advance was guarding provably did not happen. It
  /// keeps `txTime`, because the retry must reuse it or ICRC-1 cannot deduplicate.
  func unwind(i : Nat, refundPaid : Nat, err : Text) {
    let cur = progress[i];
    paidOut -= refundPaid;
    feesPaid -= feeE8s;
    progress[i] := {
      status = #Pending;
      destination = cur.destination;
      neuronId = null;
      lastError = ?err;
      attempts = cur.attempts;
      failures = cur.failures;
      txTime = cur.txTime;
    };
  };

  /// A definite outcome. Any success clears the backoff; a failure lengthens it.
  func noteSuccess() { consecutiveFailures := 0 };
  func noteFailure() { consecutiveFailures += 1 };

  /// Fixed on the first attempt, reused on every retry, so the ledger can deduplicate.
  func txTimeFor(i : Nat) : Nat64 {
    switch (progress[i].txTime) {
      case (?t) t;
      case null {
        let t = Nat64.fromNat(Int.abs(Time.now()));
        let cur = progress[i];
        progress[i] := { status = cur.status; destination = cur.destination;
                         neuronId = cur.neuronId; lastError = cur.lastError;
                         attempts = cur.attempts; failures = cur.failures; txTime = ?t };
        t;
      };
    };
  };

  /// The SNS staking subaccount for (controller, memo), byte-exact with
  /// rs/nervous_system/common/src/ledger.rs. The preimage layout is pinned by test vectors.
  func stakingSubaccount(controller : Principal, memo : Nat64) : Blob {
    Sha256.fromBlob(#sha256, L.stakingSubaccountPreimage(controller, memo));
  };

  func govAccount(sub : Blob) : ICRC.Account {
    { owner = governanceId; subaccount = ?sub };
  };

  // ── Nominating where a neuron goes ──────────────────────────────────────────────────
  //
  // Internet Identity derives a DIFFERENT principal per origin, so the principal a staker
  // used on the Menese app cannot control a neuron reached from the NNS dapp. The staker
  // therefore nominates the principal that should control it.
  //
  // The security property is unchanged: `entries[i].owner` is immutable and decides WHO is
  // entitled; the only principal allowed to nominate a destination for entry `i` is that
  // same owner. There is still no admin, and nobody can redirect anybody else's payout.
  public shared ({ caller }) func setNeuronDestination(dest : Principal) : async Result.Result<Nat, Text> {
    if (Principal.isAnonymous(caller)) return #err("anonymous cannot nominate");
    if (Principal.isAnonymous(dest)) return #err("destination cannot be anonymous");
    var n = 0;
    var i = 0;
    while (i < entries.size()) {
      if (entries[i].owner == caller) {
        switch (entries[i].payout) {
          case (#Neuron(_)) {
            // Changeable right up until the entry is paid, and frozen from then on, so a
            // mistake is recoverable but a settled neuron can never be re-pointed.
            if (not L.isTerminal(progress[i].status) and progress[i].status == #Pending) {
              let c = progress[i];
              progress[i] := { status = c.status; destination = ?dest; neuronId = c.neuronId; lastError = c.lastError; attempts = c.attempts; failures = c.failures; txTime = c.txTime };
              n += 1;
            };
          };
          case (#Liquid) {};   // a liquid payout always goes to the owner; nothing to nominate
        };
      };
      i += 1;
    };
    if (n == 0) #err("no unpaid neuron entry belongs to you") else #ok(n);
  };

  /// What the caller is owed, and whether anything of theirs is still waiting on a
  /// destination. Lets the app show a staker exactly what to do.
  public query ({ caller }) func myEntries() : async [{ index : Nat; amount : Nat; payout : T.Payout; status : T.Status; destination : ?Principal }] {
    let out = List.empty<{ index : Nat; amount : Nat; payout : T.Payout; status : T.Status; destination : ?Principal }>();
    var i = 0;
    while (i < entries.size()) {
      if (entries[i].owner == caller) {
        List.add(out, { index = i; amount = entries[i].amount; payout = entries[i].payout;
                        status = progress[i].status; destination = progress[i].destination });
      };
      i += 1;
    };
    List.toArray(out);
  };

  /// How many neuron entries are still waiting for their owner to nominate a destination.
  /// This is the number that keeps the run unsettled, so it is worth watching. These wait
  /// indefinitely and without loss; nothing expires and nobody is written off for silence.
  public query func awaitingDestination() : async Nat {
    var n = 0;
    var i = 0;
    while (i < entries.size()) {
      switch (L.resolvePayout(entries[i].payout, progress[i].destination)) {
        case (#AwaitingDestination) { if (not L.isTerminal(progress[i].status)) n += 1 };
        case (_) {};
      };
      i += 1;
    };
    n;
  };

  // ── The payout path ─────────────────────────────────────────────────────────────────
  //
  // One step per call, so a trap anywhere is resumable without re-sending money. Callable
  // by anyone: every path only ever moves an entry forward and none can redirect it.
  public shared func process(i : Nat) : async Result.Result<Text, Text> {
    await* guarded(i);
  };

  /// Busy guard plus one step. `async*` throughout: a private helper that awaits another
  /// canister MUST be `async*`, because a nested `async` future drops the mutation that
  /// runs after the await (here, releasing the busy flag) and replies with the inner
  /// value. See memory: motoko-async-star-correctness-rule.
  func guarded(i : Nat) : async* Result.Result<Text, Text> {
    if (i >= entries.size()) return #err("no such entry");
    if (not checked) return #err("verifyParameters() has not been run");
    if (busy[i]) return #err("entry busy");
    busy[i] := true;
    // Audit R-2. `await*` inlines, so `busy[i] := true` commits at the first await inside
    // `step`. If a callee REJECTS, the raised Error was previously uncaught, the message
    // trapped, and the release below never ran: the flag stayed set for the life of the
    // canister, with no admin able to clear it. The per-call handlers inside `step` unwind
    // any accounting; this one exists so the latch is released whichever await rejected.
    let r = try { await* step(i) } catch (err) {
      noteFailure();
      #err("rejected: " # Error.message(err));
    };
    busy[i] := false;
    // Per-entry bookkeeping in one place: every step outcome funnels through here. This
    // only paces the entry, it never advances or terminates it.
    setFailures(i, switch (r) { case (#ok(_)) 0; case (#err(_)) progress[i].failures + 1 });
    r;
  };

  func setFailures(i : Nat, n : Nat) {
    let cur = progress[i];
    progress[i] := {
      status = cur.status; destination = cur.destination; neuronId = cur.neuronId;
      lastError = cur.lastError; attempts = cur.attempts; failures = n; txTime = cur.txTime;
    };
  };

  func step(i : Nat) : async* Result.Result<Text, Text> {
    let e = entries[i];
    let st = progress[i].status;
    if (L.isTerminal(st)) return #ok("already terminal");

    // A neuron entry does nothing at all until its owner has nominated a destination.
    // Waiting is not failing: the entry stays claimable for as long as it takes.
    switch (L.resolvePayout(e.payout, progress[i].destination)) {
      case (#AwaitingDestination) { return #ok("awaiting a destination from the owner") };
      case (#Ready(_)) {};
    };

    switch (e.payout) {

      // ── LIQUID: one transfer, and it is finished ────────────────────────────────────
      case (#Liquid) {
        if (not L.liquidPayable(e.amount, feeE8s)) {
          setStatus(i, #Failed("amount " # Nat.toText(e.amount) # " is at or below the ledger fee; unpayable"), null, null);
          return #ok("marked unpayable");
        };
        // Mark BEFORE the transfer. Marking after is a double-spend.
        let ts = txTimeFor(i);
        setStatus(i, #Done, null, null);
        paidOut += e.amount;
        feesPaid += feeE8s;
        try {
          let res = await ledger.icrc1_transfer({
            from_subaccount = null;
            to = { owner = e.owner; subaccount = null };
            amount = e.amount;
            fee = ?feeE8s;
            memo = ?L.transferMemo(i);
            created_at_time = ?ts;
          });
          switch (res) {
            case (#Ok(_)) { noteSuccess(); #ok("paid liquid") };
            // An earlier attempt landed and its reply was lost. This is the outcome
            // the deterministic created_at_time exists to produce.
            case (#Err(#Duplicate(_))) { noteSuccess(); #ok("already paid; ledger deduplicated") };
            // The dedup window closed before the transfer could be confirmed. Guessing
            // either way is wrong: reconcile() shows which way it went, and the entry
            // is marked visibly rather than reported as paid.
            case (#Err(#TooOld)) {
              noteFailure();
              setStatus(i, #Failed("ambiguous: the ledger dedup window expired before this transfer could be confirmed; read reconcile() to determine whether it landed"), null, null);
              #err("ambiguous: dedup window expired");
            };
            case (#Err(err)) {
              // Definite failure: release the mark and the accounting, so a retry is clean.
              unwind(i, e.amount, debug_show (err));
              noteFailure();
              #err("transfer failed: " # debug_show (err));
            };
          };
        } catch (err) {
          // A REJECT, not a returned error: the ledger is stopped, upgrading or out of
          // cycles. Audit R-1/R-3. Without this the #Done mark committed above survives the
          // trap and the holder is marked paid, forever, having received nothing.
          unwind(i, e.amount, Error.message(err));
          noteFailure();
          #err("transfer rejected: " # Error.message(err));
        };
      };

      // ── NEURON: fund, claim, delay, grant, strip ────────────────────────────────────
      case (#Neuron(n)) {
        let memo = Nat64.fromNat(i);
        let sub = stakingSubaccount(Principal.fromActor(this), memo);

        switch (st) {

          // 1. Fund. Idempotent by checking the subaccount balance FIRST, not by relying
          //    on a dedup window that can expire.
          case (#Pending) {
            let stake = L.payoutAmount(e.amount, L.MIN_NEURON_STAKE_E8S);
            let bal = await ledger.icrc1_balance_of(govAccount(sub));
            if (bal >= stake) { noteSuccess(); setStatus(i, #Funded, null, null); return #ok("already funded") };
            let ts = txTimeFor(i);
            setStatus(i, #Funded, null, null);
            paidOut += stake;
            feesPaid += feeE8s;
            try {
              let res = await ledger.icrc1_transfer({
                from_subaccount = null;
                to = govAccount(sub);
                amount = stake;
                fee = ?feeE8s;
                memo = ?L.transferMemo(i);
                created_at_time = ?ts;
              });
              switch (res) {
                case (#Ok(_)) { noteSuccess(); #ok("funded") };
                case (#Err(#Duplicate(_))) { noteSuccess(); #ok("already funded; ledger deduplicated") };
                case (#Err(#TooOld)) {
                  noteFailure();
                  setStatus(i, #Failed("ambiguous: the ledger dedup window expired before this stake transfer could be confirmed; read reconcile() and the staking subaccount balance"), null, null);
                  #err("ambiguous: dedup window expired");
                };
                case (#Err(err)) {
                  unwind(i, stake, debug_show (err));
                  noteFailure();
                  #err("fund failed: " # debug_show (err));
                };
              };
            } catch (err) {
              // Audit R-1/R-4: without this the #Funded mark survives the trap and the entry
              // wedges forever against an empty staking subaccount.
              unwind(i, stake, Error.message(err));
              noteFailure();
              #err("fund rejected: " # Error.message(err));
            };
          };

          // 2. Claim the neuron, with THIS CANISTER as controller, so the delay can be set.
          case (#Funded) {
            // Audit R-4: #Funded records that the stake transfer was believed to have
            // landed, and a lost reply can make that untrue. Claiming against an empty
            // subaccount fails on every retry and the entry wedges, so the balance is
            // confirmed and the fund step re-entered rather than assumed.
            let stake = L.payoutAmount(e.amount, L.MIN_NEURON_STAKE_E8S);
            let bal = await ledger.icrc1_balance_of(govAccount(sub));
            if (bal < stake) {
              unwind(i, stake, "staking subaccount holds " # Nat.toText(bal) # ", short of " # Nat.toText(stake) # "; re-running the fund step");
              noteFailure();
              return #err("stake not present; reverted to fund");
            };
            let r = await gov.manage_neuron({
              subaccount = sub;
              command = ?#ClaimOrRefresh({
                by = ?#MemoAndController({ controller = ?Principal.fromActor(this); memo });
              });
            });
            switch (r.command) {
              case (?#ClaimOrRefresh(c)) {
                switch (c.refreshed_neuron_id) {
                  case (?nid) { setStatus(i, #Claimed, ?nid.id, null); #ok("claimed") };
                  case null { #err("claim returned no neuron id") };
                };
              };
              case (?#Error(g)) { #err("claim: " # g.error_message) };
              case (_) { #err("claim: unexpected response") };
            };
          };

          // 3. Set the dissolve delay. IncreaseDissolveDelay is ADDITIVE, so read the
          //    current value and send only the difference; a blind retry would double it.
          case (#Claimed) {
            switch (progress[i].neuronId) {
              case null { #err("no neuron id recorded") };
              case (?nid) {
                // Audit R-5: the floor was verified once, at verifyParameters. The DAO can
                // raise it by proposal mid-run, and every neuron issued after that would be
                // correctly owned, correctly funded and silently unable to vote: the exact
                // outcome verifyParameters exists to prevent. Re-read it here, per neuron,
                // so the guard is not merely looser in time than the thing it guards.
                let live = await gov.get_nervous_system_parameters();
                switch (live.neuron_minimum_dissolve_delay_to_vote_seconds) {
                  case (?f) {
                    if (n.delaySeconds < f) {
                      noteFailure();
                      return #err("REFUSING: this entry's delay " # Nat64.toText(n.delaySeconds)
                                  # "s is below the live voting floor " # Nat64.toText(f)
                                  # "s; issuing it would produce a neuron that cannot vote");
                    };
                  };
                  case null {};
                };
                let cur = await gov.get_neuron({ neuron_id = ?{ id = nid } });
                let have : Nat64 = switch (cur.result) {
                  case (?#Neuron(nn)) {
                    switch (nn.dissolve_state) {
                      case (?#DissolveDelaySeconds(s)) s;
                      case (_) 0;
                    };
                  };
                  case (_) 0;
                };
                if (have >= n.delaySeconds) { setStatus(i, #Delayed, null, null); return #ok("delay already set") };
                let add = n.delaySeconds - have;
                let r = await gov.manage_neuron({
                  subaccount = sub;
                  command = ?#Configure({
                    operation = ?#IncreaseDissolveDelay({
                      additional_dissolve_delay_seconds = Nat32.fromNat(Nat64.toNat(add));
                    });
                  });
                });
                switch (r.command) {
                  case (?#Error(g)) { #err("configure: " # g.error_message) };
                  case (_) { setStatus(i, #Delayed, null, null); #ok("delay set") };
                };
              };
            };
          };

          // 4. GRANT to the holder. From here the holder owns the neuron outright and
          //    no action or inaction by this canister can take it away.
          case (#Delayed) {
            // The permission ids are defined by governance. A hardcoded list here
            // named one id more than the enum defines, and governance refused every grant
            // with "provided more permissions than exist in the system", funded, claimed,
            // correctly delayed, and then wedged for ever with this canister as the sole
            // controller. Read the live set and use it verbatim; it cannot be too long, and
            // it cannot contain something this SNS will not grant.
            let live = await gov.get_nervous_system_parameters();
            let grantable : [Int32] = switch (live.neuron_grantable_permissions) {
              case (?l) l.permissions;
              case null {
                noteFailure();
                return #err("REFUSING: governance did not report neuron_grantable_permissions; a guessed list is what wedged this step before");
              };
            };
            // Fail closed. Granting an empty set would leave a neuron the holder cannot
            // control while marking the entry #Granted, which is the one status past which
            // the canister assumes the holder is whole.
            if (not L.grantableIsUsable(grantable)) {
              noteFailure();
              return #err("REFUSING: governance reports an empty grantable permission set; the holder would not control the neuron");
            };
            let holder = L.recipient(e.owner, progress[i].destination, e.payout);
            let r = await gov.manage_neuron({
              subaccount = sub;
              command = ?#AddNeuronPermissions({
                principal_id = ?holder;
                permissions_to_add = ?{ permissions = grantable };
              });
            });
            switch (r.command) {
              // Audit R-1: a governance-returned error is a failure like any other. It was
              // not counted before, so the backoff never engaged and a permanently failing
              // grant was retried every 15 seconds for ever.
              case (?#Error(g)) { noteFailure(); #err("grant: " # g.error_message) };
              case (_) { noteSuccess(); setStatus(i, #Granted, null, null); #ok("granted to holder") };
            };
          };

          // 5. Strip ourselves. Deliberately last: a trap between 4 and 5 leaves a neuron
          //    the holder fully controls, which is repairable. The reverse order could
          //    leave one nobody controls, which is not.
          case (#Granted) {
            let me = Principal.fromActor(this);
            // Remove exactly the permissions the neuron records for this canister.
            // Neither a hardcoded list nor a re-read of `neuron_claimer_permissions` is
            // safe: the first can name ids that do not exist, and the second is a
            // parameter the DAO can change between the claim and this call, leaving
            // permissions held but never removed. The neuron is authoritative.
            let nid = switch (progress[i].neuronId) {
              case (?n) n;
              case null { noteFailure(); return #err("no neuron id recorded") };
            };
            let cur = await gov.get_neuron({ neuron_id = ?{ id = nid } });
            let mine : [Int32] = switch (cur.result) {
              case (?#Neuron(nn)) { L.permissionsOf(nn.permissions, me) };
              case (_) { noteFailure(); return #err("strip: could not read the neuron back") };
            };
            // Already stripped: a previous attempt landed and its reply was lost.
            if (mine.size() == 0) { noteSuccess(); setStatus(i, #Done, null, null); return #ok("already stripped") };
            let r = await gov.manage_neuron({
              subaccount = sub;
              command = ?#RemoveNeuronPermissions({
                principal_id = ?me;
                permissions_to_remove = ?{ permissions = mine };
              });
            });
            switch (r.command) {
              case (?#Error(g)) { noteFailure(); #err("strip: " # g.error_message) };
              case (_) { noteSuccess(); setStatus(i, #Done, null, null); #ok("done") };
            };
          };

          case (_) { #ok("nothing to do") };
        };
      };
    };
  };

  /// Advance the first entry that is not finished. This is what the timer drives, and what
  /// anyone can call if the timer is ever wedged.
  public shared func processNext() : async Result.Result<Text, Text> {
    await* nextStep(false);
  };

  /// Advance one entry, starting the scan at the rotating cursor.
  ///
  /// `paced` applies the per-entry backoff and is set only by the timer. A caller driving
  /// the table by hand is never paced, so `processNext()` can always make progress if any
  /// entry can.
  func nextStep(paced : Bool) : async* Result.Result<Text, Text> {
    let n = entries.size();
    if (n == 0) return #ok("empty table");
    var step = 0;
    var held = 0;
    while (step < n) {
      let i = L.scanIndex(cursor, step, n);
      if (not L.isTerminal(progress[i].status)) {
        // An entry still waiting on its owner is skipped, not attempted: waiting is not
        // failing, and it must not hold up the entries behind it.
        switch (L.resolvePayout(entries[i].payout, progress[i].destination)) {
          case (#AwaitingDestination) {};
          case (#Ready(_)) {
            if (not paced or L.entryMayAttempt(tick, progress[i].failures)) {
              // Move the cursor BEFORE attempting, so an entry that traps or rejects still
              // yields its turn to the next one.
              cursor := L.advanceCursor(i, n);
              return await* guarded(i);
            };
            held += 1;
          };
        };
      };
      step += 1;
    };
    if (held > 0) {
      #ok("nothing attempted this tick: " # Nat.toText(held) # " entr(ies) held by per-entry backoff");
    } else {
      #ok("nothing actionable: table exhausted or awaiting destinations");
    };
  };

  // ── The push ────────────────────────────────────────────────────────────────────────
  // Nobody has to claim. Nobody is missed for not reading the announcement.
  transient let _ticker = Timer.recurringTimer<system>(#seconds 15, func() : async () {
    if (not checked) return;
    tick += 1;
    // Audit R-1: back off while the ledger or governance is rejecting. Unconditional
    // attempts are what turned one outage into a walk through the whole table. Exponential,
    // capped at an hour, and cleared entirely by the first success, so recovery is
    // automatic and needs neither an operator nor any new authority.
    if (not L.mayAttempt(tick, consecutiveFailures)) return;
    ignore await* nextStep(true);   // await*, never a self-call to the public method
  });

  // ── Read-only surface ───────────────────────────────────────────────────────────────

  /// The whole eligible set, readable by any caller. No inclusion proof is required.
  public query func getTable() : async [T.Entry] { entries };

  public query func getProgress() : async [T.Progress] { Array.fromVarArray(progress) };

  func statsOf() : T.Stats {
    var done = 0; var granted = 0; var failed = 0; var pending = 0; var oblig = 0;
    var i = 0;
    while (i < entries.size()) {
      oblig += entries[i].amount;
      switch (progress[i].status) {
        case (#Done) { done += 1; granted += 1 };
        case (#Granted) { granted += 1 };
        case (#Failed(_)) { failed += 1 };
        case (_) { pending += 1 };
      };
      i += 1;
    };
    { entries = entries.size(); done; granted; failed; pending;
      paidOut; totalObligation = oblig; initialReserve; feesPaid };
  };

  public query func stats() : async T.Stats { statsOf() };

  /// INV-R1. Both operands are returned, so the result is independently checkable.
  func reconcileNow() : async* T.Reconciliation {
    let bal = await ledger.icrc1_balance_of({ owner = Principal.fromActor(this); subaccount = null });
    L.reconcile(initialReserve, paidOut, feesPaid, bal);
  };

  public shared func reconcile() : async T.Reconciliation { await* reconcileNow() };

  /// Has every entry reached a terminal status, with the books balancing?
  ///
  /// This gates nothing. The canister is never blackholed; it stays under SNS DAO control
  /// for life, so there is no irreversible step for a precondition to guard. It exists so
  /// the DAO can see, in one call, that the run is finished and what it wrote off.
  /// `writtenOff` is reported as a number rather than folded into the verdict, because an
  /// unpayable account is a fact the DAO should read, not a detail buried in a boolean.
  public shared func settlement() : async { settled : Bool; writtenOff : Nat; reason : Text } {
    let s = statsOf();
    let r = await* reconcileNow();
    let done = L.settled(s, r);
    {
      settled = done;
      writtenOff = s.failed;
      reason = if (done and s.failed == 0) { "every entry paid, books balance" }
               else if (done) { "every entry resolved, books balance; " # Nat.toText(s.failed) # " written off as unpayable" }
               else if (s.done + s.failed != s.entries) {
                 Nat.toText(s.entries - s.done - s.failed) # " entr(ies) still in flight" # stalledNote();
               }
               else { "reserve does not reconcile" };
    };
  };

  /// Names the entry a stalled table is stalled on, so "nothing is moving" is answerable
  /// without reading the whole progress array. A repeatedly failing entry no longer holds up
  /// the ones behind it, but it is still the thing an operator wants named.
  func stalledNote() : Text {
    let failures = Array.tabulate<Nat>(entries.size(), func(i) { progress[i].failures });
    let terminal = Array.tabulate<Bool>(entries.size(), func(i) { L.isTerminal(progress[i].status) });
    switch (L.mostFailed(failures, terminal)) {
      case null { "" };
      case (?i) {
        "; entry " # Nat.toText(i) # " has failed " # Nat.toText(progress[i].failures)
        # " consecutive attempt(s)"
        # (switch (progress[i].lastError) { case (?e) ": " # e; case null "" });
      };
    };
  };
}

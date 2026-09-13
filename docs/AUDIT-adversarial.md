# Adversarial audit, redemption canister, 2026-09-08

Method: a three-lens sweep: an exhaustive surface pass, verification that each proposed
remedy actually closes what it claims to, and a defect-class sweep with graded evidence.
Every checklist line is marked `FOUND` or `SWEPT-CLEAN (reason)`; none is left blank.

Target: the repository at `552f143`, 1,695 LOC Motoko, moc 1.4.1. Holds a reserve funded
once from treasury and pays a few hundred entries. **Not deployed.** All findings are
against code that has never held funds.

**Evidence grades.** `CONFIRMED`: every causal link read and quoted at an exact
`file:line`, not executed. `REPRODUCED`, shown live. `UNREPRODUCED`, shape is real, at
least one link is an estimate. Nothing here is graded above what was actually done.

---

## Summary

| # | Severity | Finding | Grade | Clears by |
|---|---|---|---|---|
| R-1 | **Critical** | A ledger outage marks **every** entry `#Done` without paying anyone, irreversibly | **REPRODUCED** | code change |
| R-2 | **Critical** | A rejected inter-canister call latches `busy[i]` permanently | **REPRODUCED** | code change |
| R-3 | **Critical** | Liquid entry commits `#Done` before the transfer; the holder is permanently unpaid | **REPRODUCED** | code change |
| R-4 | **High** | Neuron entry commits `#Funded` before the transfer; entry wedges and the driver parks behind it | CONFIRMED | code change |
| R-5 | Medium | `checked` is a one-time gate; a mid-run floor rise yields the voteless neurons it exists to prevent | CONFIRMED | code change |
| R-6 | Medium | `process` / `processNext` are unauthenticated and uncapped, cycle drain | CONFIRMED | code change + ops |
| R-7 | Low | `getTable()` publishes every holder principal and amount, contradicting the stated privacy posture | CONFIRMED | decision |

**Read R-1 first. It is the finding that should stop a deploy**, and it is reproduced, not
argued. None of these is attacker-triggered. All the critical ones are triggered by the
ledger being briefly unavailable, stopped, mid-upgrade, or out of cycles, which is an
ordinary event, not an exotic one.

### Remediation status, 2026-09-08

| # | State |
|---|---|
| R-1 | **FIXED**, unwind on reject, deterministic `created_at_time` + memo, exponential driver backoff |
| R-2 | **FIXED**, `try`/`catch` in `guarded` releases the latch whichever await rejected |
| R-3 | **FIXED**: the `#Done` mark and the accounting are unwound; `#Duplicate` counts as paid; `#TooOld` is marked ambiguous rather than guessed |
| R-4 | **FIXED**, unwind on the fund reject, plus a balance re-check on entering `#Funded` |
| R-5 | **FIXED**: the floor is re-read per neuron, in the `#Claimed` branch |
| R-6 | **OPEN**, needs your decision, see below |
| R-7 | **OPEN**, needs your decision, see below |

Build `8196485adbba80dade277961d2436a32`. Suites: 107 pure-logic, 27 e2e, 15 reject
regression, all green. `test/repro-reject.sh` was inverted from a demonstration of the defect
into the regression test for the fix, against the same trapping ledger.

**The fix is proved non-vacuous.** Removing the `unwind` from the liquid reject handler
takes that suite from 15/15 to 7 passed / 8 failed, reproducing the original symptoms
exactly: entry 0 reports `Done`, the holder is credited 0, `reconcile` stops balancing.

**R-6 and R-7 are deliberately not fixed**, because both change a property that was chosen on
purpose; each is a governance decision, not a code change. R-6's remedy would restrict who may drive
the payout, which is currently *anyone* by design so a wedged timer can be worked around; and
the real mitigation is a named owner for cycle monitoring, which is an operational decision
the never-blackhole choice created. R-7 is a straight decision about whether the holder table
is public on-chain, and it currently is, and the argument for that is good, but it contradicts
how the table is handled off-chain, and holders should be told.

### Correction to this audit

The first draft filed R-1 as *"`nextStep` parks the entire remaining table on any entry that
cannot progress"*, graded CONFIRMED. **Running it proved that wrong, in the reassuring
direction.** The driver does not park on a failed liquid entry, because the liquid failure
path marks the entry `#Done`, terminal, *before* the transfer. Terminal entries are
skipped, so the driver **advances and destroys the next entry the same way**, once every 15
seconds, until the table is exhausted.

The parking behaviour described above is real, but only for the neuron `#Funded` wedge (R-4),
where the entry stays non-terminal. Filing it as the general case understated a cascade as a
halt. This is recorded here rather than silently amended because a count is meaningless net
of what did not hold.

---

## R-1: a ledger outage destroys the whole table · Critical · REPRODUCED

**This is the deploy blocker.** Reproduced live on a clean replica by
`test/repro-reject.sh`, against a `MockLedger` armed to trap rather than return an error:
a ledger that is stopped, mid-upgrade, or out of cycles rejects exactly this way.

Result on a three-entry table:

```
getProgress →  1 Done   2 Done   3 Done
stats       →  done = 3   pending = 0   failed = 0
balances    →  holder A 0   holder B 0   holder C 0
totalHeld   →  the reserve still holds every token
```

**Every entry reports paid. Nobody received anything. Nothing is left pending to retry.**

The mechanism is R-3 applied repeatedly. The liquid path marks `#Done` and increments
`paidOut` *before* `await ledger.icrc1_transfer` (`Redemption.mo:226-229`). Those writes
commit at the await. A reject then traps the message, discarding only the current slice, so
the mark survives and the transfer never happened. `#Done` is terminal, `canAdvance`
(`Logic.mo:110-116`) admits nothing out of a terminal status, and there is no admin, so
that entry is finished, wrongly, forever.

Then the driver moves on. `nextStep` (`Redemption.mo:384-398`) skips terminal entries, so
the freshly-destroyed entry is skipped and the next one is taken. The 15-second timer
(`:402-405`) repeats this every tick and discards the result (`ignore await* nextStep()`),
so **the destruction is silent**, no log, no trap that anybody sees, no alert.

Scaled to a full table: **a ledger outage of roughly (entries × 15 s): an hour and a half
for a few hundred entries, marks every entry paid, pays nobody, and cannot be undone.**
A shorter outage destroys a proportional prefix. Ledger upgrades routinely take a canister offline for longer than one tick.

`reconcile()` does detect it, INV-R1 reports `holds = false`, verified in the run, but
detection after the fact is not a remedy, because there is no path back out of `#Done`.

**Remedy.** Three changes, and all three are needed:

1. **Do not let a reject commit a mark.** Wrap the ledger call in `try`/`catch` (moc 1.4.1
   supports it) and roll the status and accounting back in the catch, exactly as the
   returned-`#Err` path already does at `:239-245`. This is what converts a reject from
   "destroys the entry" into "retries the entry".
2. **Make the retry safe**, per R-3: `created_at_time` is `null` at `:235`, so ICRC-1
   deduplication is off and a naive retry after an ambiguous outcome double-pays. Set a
   deterministic `created_at_time` and `memo`, and state the ledger's transaction window as
   the parameter the safety rests on.
3. **Stop the driver during an outage.** A consecutive-failure counter that halts the timer
   after a small number of rejects turns a 90-minute outage into a handful of retries
   instead of a whole table of destroyed entries. Without this, 1 and 2 still leave every entry being
   attempted and rolled back once per tick for the duration.

**Acceptance criteria.** `test/repro-reject.sh` must invert: after the same trapping-ledger
run, assert every entry is back at `#Pending`, `paidOut == 0`, `reconcile().holds == true`,
and that once the ledger recovers all three entries reach `#Done` **and** all three holders
are credited exactly once. Injected defect: remove the catch; the test must fail.

---

## R-2: a rejected call latches `busy[i]` forever · Critical · REPRODUCED

`Redemption.mo:195-203`:

```
busy[i] := true;
let r = await* step(i);
busy[i] := false;   // reached, because `await*` inlines rather than nesting a future
```

The comment is true for the normal path and false for the failing one. `await*` inlines, so
the first real commit point is the first `await` inside `step`, `Redemption.mo:229`
(liquid transfer) or `:260` (balance read). `busy[i] := true` executes *before* that await
and is therefore committed when the outbound call is made.

If the callee **rejects**, ledger stopped, mid-upgrade, out of cycles: the await raises an
`Error`. There is **no `try`/`catch` anywhere in `src/`** (verified by grep across all five
modules), so it is uncaught and the message traps. A trap discards only the current slice.
The earlier slice already committed. `busy[i]` stays `true`.

`busy` is `transient` (`Redemption.mo:67`), so it survives until the next upgrade. It cannot
be cleared by any method, because there is no admin. Entry `i` then returns
`#err("entry busy")` forever. Observed in the run: the second `process(0)` answers
`entry busy`, and that is what makes R-3's damage unrepairable even by re-driving.

Note `transient` is the *right* choice here and is not the defect: a stable `busy` would
wedge identically and would additionally survive upgrades. The defect is the absent
unwind.

**Remedy, and proof it closes.** Wrap the call in `try { ... } catch (e) { busy[i] := false; ... }`.
moc 1.4.1 supports this. A rejected inter-canister call surfaces as a catchable `Error`, so
the catch runs in the same slice and the release commits, that closes the reachable
trigger. It does **not** close a genuine trap inside this canister, which is uncatchable; if that
matters, derive the guard from `status` plus an attempt timestamp rather than a separate
latch. State which of the two you are buying.

**Acceptance criteria.** A mock ledger that rejects (not `#Err`-returns) on the first call;
assert `busy` is released and a second `process(i)` is admitted rather than answering
`entry busy`. Injected defect: remove the catch; the test must fail.

---

## R-3: a liquid holder can be permanently unpaid · Critical · REPRODUCED

`Redemption.mo:226-246`. The order is: `setStatus(i, #Done)`, `paidOut += e.amount`,
`feesPaid += feeE8s`, **then** `await ledger.icrc1_transfer`.

The file's own header (`Redemption.mo:13-14`) states the reasoning: *"Status is written
BEFORE the call it guards, never after. A Motoko `await` is a commit point, so marking after
a transfer is a double-spend."* That is correct about double-spend, and it trades it for a
different loss.

Three outcomes, not two. A `#Ok` pays. A returned `#Err` is handled at `:239-245`, which
rolls the mark and the accounting back, correct, because a returned error is a *definite*
failure. The third outcome is a **reject or lost reply**, which is not handled: the mark and
the accounting are already committed, the transfer did not happen, and `#Done` is terminal.
`canAdvance` (`Logic.mo:110-116`) admits nothing out of a terminal status, and there is no
admin. **That holder is never paid and cannot be made payable.**

`reconcile()` does detect it, `expectedBalance` drops below the real balance, so INV-R1
reports `holds = false`. Detection without a remedy, but the books do not lie.

The asymmetry is the tell. The neuron path pre-checks the subaccount balance before funding
(`Redemption.mo:260-261`) precisely so a retry is idempotent. The liquid path has no
equivalent, and `created_at_time = null` at `Redemption.mo:235`, so ICRC-1 deduplication is
**off**, and there is no dedup window to make a retry safe either.

**Remedy, and proof it closes, at a stated parameter.** Set `created_at_time` to a value
derived deterministically from the entry (not `now`, which changes per retry) and a
deterministic `memo`, then treat an ambiguous outcome as retryable. ICRC-1 dedup then makes
the retry return `#Err(#Duplicate)` rather than transferring again, **for as long as the
ledger's transaction window holds**, that window is the parameter, typically 24 hours, and
it must be read from the deployed ledger, not assumed. Outside the window, dedup no longer
applies and the retry must fall back to a balance check on the recipient, which is only
sound if the recipient account is otherwise inactive. Say which regime you are relying on.

A remedy that does **not** work: rolling `#Done` back to `#Pending` on an ambiguous outcome
without dedup. With `created_at_time = null` that is a double-payment, not a fix.

**Acceptance criteria.** A mock ledger that rejects after having applied the transfer;
assert exactly one credit at the recipient across two `process(i)` calls, and that the entry
finishes `#Done`.

---

## R-4: a neuron entry can wedge at `#Funded` · High · CONFIRMED

`Redemption.mo:262-281`, same mechanism as R-3. `setStatus(i, #Funded)` and the accounting
commit before `await ledger.icrc1_transfer` at `:265`. A returned `#Err` rolls back at
`:275-280`. A reject does not.

The entry is then `#Funded` with an empty staking subaccount. The next step
(`Redemption.mo:285-302`) calls `ClaimOrRefresh`, which fails against an unfunded
subaccount, returns `#err`, and does not call `setStatus`, so the status never moves. The
entry retries forever, and by R-1 the table halts behind it. `paidOut` is overstated by the
stake, so INV-R1 flags it.

Unlike R-3 the tokens are not lost, and they are still in the reserve, but there is no method
that can re-drive the fund step, because `canAdvance` (`Logic.mo:110-116`) refuses to move
`#Funded` back to `#Pending`.

**Remedy.** Same `try`/`catch` unwind as R-2, plus: on entering the `#Funded` branch,
re-check the subaccount balance and fall back to the fund step when it is short. That check
already exists at `:260` for the `#Pending` branch; the fix is to consult it from `#Funded`
too rather than assuming the transfer landed.

**Acceptance criteria.** Force a reject on the fund transfer; assert the entry still reaches
`#Done` on subsequent ticks and the neuron holds the full stake.

---

## R-5: the floor is verified once, not per payout · Medium · CONFIRMED

`Redemption.mo:75-91` reads the live
`neuron_minimum_dissolve_delay_to_vote_seconds` and sets `checked := true` at `:85`. Nothing
ever re-reads it. `verifyParameters` is callable by anyone, which is fine, and it can only
succeed when the live floor is at or below the compiled-in floor.

But the run spans many blocks, and `neuron_minimum_dissolve_delay_to_vote_seconds` is a
governance parameter the DAO can raise by proposal mid-run. Every neuron issued after such a
change would be correctly owned, correctly funded, and **silently unable to vote**, the
exact outcome the check exists to prevent, described in those words at `Redemption.mo:71-73`.

**Remedy, with its cost stated.** Re-read the floor inside the `#Claimed` branch before
setting the delay, and fail that entry rather than issuing a voteless neuron. Cost: one
extra inter-canister call per neuron, 228 calls across the real table. A cheaper variant,
re-verifying on a slow timer, narrows the window but does not close it, because a payout can
still land between two re-verifications. Choose deliberately.

**Acceptance criteria.** Mock governance raises the floor after `verifyParameters` succeeds;
assert no neuron is issued below the new floor.

---

## R-6, unauthenticated, uncapped drive methods · Medium · CONFIRMED

`process` (`:187`) and `processNext` (`:380`) are `public shared` with no caller check and no
rate limit. This is deliberate and documented at `Redemption.mo:185-186`, anyone can drive
the payout if the timer wedges, and the safety argument holds: every path only moves an
entry forward and none can redirect a payout.

The cost side was not considered. Ingress messages are paid by the *canister*, not the
caller. An attacker can loop `processNext()` indefinitely; each call walks the whole table
and, while entries remain live, triggers inter-canister calls. The canister has no admin, no
cycle floor, and no throttle. Because it is DAO-governed for life rather than blackholed,
the DAO can top it up, so this is a drain, not a permanent kill.

**Remedy, and its honest limit.** Rejecting anonymous callers raises the cost of the cheapest
attack but does not stop a funded one, so it is a partial fix and should be described as
one. A per-caller minimum interval, or a cheap early return once `settled` holds, bounds the
steady-state cost. Neither removes the need for cycle monitoring, which is an operational
requirement of the never-blackhole decision and currently has no owner.

**Acceptance criteria.** Assert a bounded per-call instruction cost once the table is
exhausted, and that a repeat caller inside the interval is refused before any inter-canister
call is made.

---

## R-7: the table is public on-chain, which contradicts the stated posture · Low · CONFIRMED

`getTable()` (`Redemption.mo:410`) returns every entry, owner principal and amount, to any
caller. That is deliberate and defended at `:409`: *"No proof plumbing: everyone can simply
read it."*

It sits badly with how the table is handled off-chain, where the design tree is kept out of
any repository specifically because it contains the full holder table with principals. Both cannot be
the operative privacy posture. The canister publishes on-chain, forever, exactly what the
repository withholds.

This is a decision, not a defect, and the on-chain publication is probably the right one:
public verifiability of who was eligible is the point. But the two documents should agree,
and holders should be told their principal and balance become public, because with the
snapshot published alongside the module hash they become permanently linkable.

---

## Checklist dispositions

**A. Bounds & resources**
- Unbounded walk sized by the caller, SWEPT-CLEAN: every walk is over `entries`, fixed at
  install; no caller-supplied collection exists.
- Cap on the wrong dimension, SWEPT-CLEAN: no byte-variable cost; amounts are `Nat` scalars.
- Batch multiplying an O(S) walk, SWEPT-CLEAN: no batch endpoint exists at all.
- Unbounded persistent growth, SWEPT-CLEAN: `progress` is `VarArray.repeat` sized at install
  (`:59-60`); nothing appends; no per-caller storage.
- Instruction-budget guards, **FOUND (R-6)**: none exist; every bound is structural.
- Exhaustion flipping a verdict, SWEPT-CLEAN: `settled` is computed from counts, not from a
  bounded scan that can run out.

**B. Latches, commit points, recovery**
- Rollback leaving a latch set, **FOUND (R-2)**.
- Poison-pill precondition re-arming per attempt, **FOUND (R-4)**.
- What commits before the await / lost reply, **FOUND (R-3, R-4)**.
- Partial settlement returning an error that hides what moved, SWEPT-CLEAN: single-leg
  operations only; no path settles one leg and reports failure on another.
- Dead retry counter, PARTIAL: `attempts` (`Types.mo:66`) increments but nothing reads it.
  No cap, no expiry, no admin cancel. Harmless today; it is the natural place to hang the
  R-1 cursor's skip logic.
- Single-flight on the timer, SWEPT-CLEAN: `busy` provides per-entry single-flight
  (`:198`); the defect is its unwind, not its presence.
- Trap in a maintenance tick stopping maintenance, SWEPT-CLEAN: the stuck paths return
  `#err` rather than trapping, so the timer keeps ticking. This is *why* R-1 is silent.

**C. Checks that do not check**
- A test that cannot fail, SWEPT-CLEAN, and actively guarded: the suite carries 11 injected
  defects, and the vacuous absolute-vs-additive control was caught and repaired
  (`build/BUILD.md`).
- Runner discarding a failure count, SWEPT-CLEAN: `run_tests.mo` traps on any failure.
- Structurally inert gates, SWEPT-CLEAN.
- Verifier not anchored to a trusted root, SWEPT-CLEAN: `verifyParameters` reads live
  governance, not a local constant, which is the anchor.
- Detector looser than the protocol, **FOUND (R-5)**: the floor check is correct but runs
  once, so it is looser in *time* than the protocol it guards.
- Unfalsifiable criterion, SWEPT-CLEAN: `settled` was unfalsifiable before `552f143` and is
  now asserted true and false in the same e2e run.
- Constants missing `transient`, SWEPT-CLEAN, inverted: the constants are deliberately
  immutable, which is the design.

**D. Authority, privacy, scoping**
- Unauthenticated config / first-caller-wins admin, SWEPT-CLEAN: no config method exists;
  `verifyParameters` only sets a flag gated on live governance agreeing.
- Endpoints returning rows not scoped to the caller, **FOUND (R-7)**, deliberate.
  `myEntries` (`:154`) is correctly scoped by `entries[i].owner == caller`.
- Two endpoints jointly republishing what a third protects, SWEPT-CLEAN: `getTable` already
  publishes everything, so there is nothing left to protect jointly.
- Documented guarantee contradicted by code, **FOUND (R-7)**, and previously found in the
  blackhole guarantee, corrected when the never-blackhole decision was taken.
- Gates default-off on the value path, SWEPT-CLEAN: `checked` defaults **false** and
  `guarded` refuses without it (`:197`).

**E. Quantities & asymmetry**
- Which quantity each guard evaluates, verified: `liquidPayable` tests `amount > fee`
  (`Logic.mo:63`), gross against the fee, correct because the ledger debits the fee from the
  sender. `payoutAmount` rounds up to `MIN_NEURON_STAKE_E8S` (`Logic.mo:53`).
- Paired operations over different quantities, **FOUND (R-3)**: the neuron path pre-checks a
  balance for idempotency and the liquid path does not.
- Symmetric variants, one handled and its twin not, **FOUND (R-3, R-4)**: `#Err` handled,
  reject not, on both transfers.
- Decimal/scaling errors, SWEPT-CLEAN: single 8-decimal token throughout; no cross-decimal
  arithmetic. `Nat32.fromNat(Nat64.toNat(add))` (`:326`) narrows unchecked, but every
  `delaySeconds` in the frozen table is bounded far below 2³²; noted, not filed.

**F. Supply chain & ops**
- Third-party scripts, CSP, SRI, N/A, no frontend in this repo.
- Trust root fetched from the host being verified, SWEPT-CLEAN: governance is the authority
  on its own parameter, which is correct, not circular.
- Vendored prebuilt binaries, SWEPT-CLEAN: none; `build/redemption.wasm` is reproducible
  from source with a recorded md5.
- Deploy scripts, `/tmp` injection, key pre-authorisation, SWEPT-CLEAN: no deploy script in
  the repo; installation is a documented manual `dfx` invocation.
- Module-hash verification, PARTIAL: `build/BUILD.md` records the md5 and the install path
  is `--wasm`, but no step *verifies* the installed module hash against it on mainnet. Worth
  adding to the installation runbook.

**G. Remedy discipline**
- Every identifier above was re-derived from source by grep or direct read before filing.
  No constant is cited that was not seen.
- Every remedy states what it closes and at what parameter, and R-3 and R-6 state explicitly
  what their remedy does **not** close.

---

## What this audit cannot tell you

R-1, R-2 and R-3 are **reproduced**: `test/repro-reject.sh`, 13 assertions, 0 failures, on a
clean replica against a `MockLedger` armed to trap. Reproducing them is what corrected R-1
from a halt to a cascade, so the demonstration earned its cost immediately.

R-4 through R-7 are **CONFIRMED only**, read at exact lines, not executed:

- **R-4** shares R-3's mechanism on a path the harness does not yet drive, so it is the
  best-supported of the four. Driving it needs a mock governance that rejects, which is the
  same one-line addition made to `MockLedger` here.
- **R-5** needs mock governance to raise the floor mid-run.
- **R-6** is an arithmetic claim about who pays for ingress. No counterexample appeared, but
  no instruction-count measurement was taken either, so the *size* of the drain is
  unquantified.
- **R-7** is a design contradiction rather than a behaviour; nothing would be learned by
  running it.

One surface this audit did not examine at all: the **snapshot pipeline** that produces the
the whole table. The snapshot builder and the disjointness assertion live outside this repository,
not this repo, and a defect there puts a wrong table into a constructor argument that no
method can ever correct. That needs its own pass with access to that tree, before the table
is compiled in.

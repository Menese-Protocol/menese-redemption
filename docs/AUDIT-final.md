# Final audit, MENES redemption canister

2026-09-08. Class sweep, graded evidence, every class dispositioned, nothing upgraded to
flatter a finding. This is the closing document. The adversarial pass that found the
critical defects is `AUDIT-adversarial.md` and is not restated here.

**Scope.** `src/`, five modules, 1,695 LOC before the fixes, plus the build. **Out of
scope and never audited: the snapshot pipeline**, which lives outside this repository and
produces the table. That is the largest remaining unexamined surface and it is named again
at the end.

---

## Verdict

**The canister is sound on the classes examined, and is not yet deployable.** What stands in
the way is not code: it is two decisions for the maintainers (R-6, R-7) and one unaudited
input (the snapshot).

| | |
|---|---|
| Pure-logic battery | 107 checks, 0 failures |
| End-to-end on a replica | 27 checks, 0 failures |
| Reject regression | 15 checks, 0 failures |
| Negative controls | 12 injected defects, 12 caught |
| Build | `8196485adbba80dade277961d2436a32`, 756,044 bytes, moc 1.4.1 |
| Reproducible | **yes**, byte-identical across directories, `verification/verify-build.sh` 6/6 |

---

## 1. Motoko institutional knowledge: every rule, dispositioned

The house Motoko rules (the project's Motoko conventions) plus the findings this project has
paid for. A rule that does not apply gets a reason, not a blank.

### 1.1 `mo:core`, not `mo:base`

| Rule | Disposition |
|---|---|
| Use `mo:core` | **CLEAN**: every import in `src/` is `mo:core/*` or `mo:sha2`. No `mo:base` anywhere. |
| `List`/`Map`/`Set` are mutable, no reassignment | **CLEAN**, `List` is used once, in `myEntries`, as a local accumulator via `List.add`. No reassignment. |
| `Map.add` not `Map.put` | **N/A in `src/`**, no `Map`. Used correctly in `test/MockLedger.mo`. |
| `.values()` not `.vals()` | **CLEAN**, `Logic.mo` uses `.values()` in `roundUpCost` and `reserveNeeded`. Zero `.vals()`. |
| `Iter.range` is gone; use `Nat.range` | **CLEAN**, neither appears. Every loop is an explicit `while` with a `Nat` cursor, which is also why the table walks are obviously bounded. |
| `Runtime.trap` not `Debug.trap` | **CLEAN in `src/`**, neither appears; the canister has no trap of its own. `Runtime.trap` is used correctly in the mock, to model a rejecting ledger. |

### 1.2 `persistent actor` and upgrade safety

| Rule | Disposition |
|---|---|
| `persistent actor` | **CLEAN**, `persistent actor class Redemption`. |
| Never `transient` for state that must survive an upgrade | **CLEAN, and deliberate.** Three things are `transient`: the two service handles, which must be re-derived, and `busy`, which is a per-message latch that *should* clear on upgrade. Everything durable, `entries`, `progress`, `paidOut`, `feesPaid`, `checked`, `consecutiveFailures`, `tick`, is implicitly stable. |
| Externalise state to record types + module functions | **CLEAN**, `Types.mo` holds the records, `Logic.mo` the pure functions, and the battery drives `Logic` directly with no replica. |
| Never `--wasm-memory-persistence replace`, never `--mode reinstall` | **APPLIES AT INSTALL, not yet.** Worth restating: this canister's `entries` are a constructor argument, so a reinstall does not merely wipe progress, it re-seeds the table. |
| M0169 needs a real migration function | **NOT YET APPLICABLE**, never deployed, so there is no live signature to be compatible with. **The gate for the first upgrade after install is `moc --stable-compatible live.most new.most`**, run with the moc that built the live module. Note a lesson learned earlier: the empty test canisters cannot rehearse an upgrade, so `--stable-compatible` is the only real gate, not a dry run. |

⚠️ **One upgrade hazard this canister creates for itself.** `progress` is sized from
`entries.size()` at initialisation via `VarArray.repeat`. `entries` is immutable, so the two
cannot drift, but any future change that alters the `Progress` record changes the stable
signature. The `txTime` field added by the audit fix is exactly such a change, and it was
free only because nothing is deployed. After install, adding a field is an upgrade with a
compatibility gate, not an edit.

### 1.3 `async*`, and the bug that was already live here

| Rule | Disposition |
|---|---|
| `async*` for private helpers that await | **CLEAN, and load-bearing.** `guarded`, `step`, `nextStep`, `reconcileNow` are all `async*`/`await*`. |
| Module public funcs converted too | **N/A**, `Logic` and `Types` are pure; no module function awaits. |
| Timer callbacks need the special pattern | **CLEAN**: the ticker calls `await* nextStep()`, never a self-call to the public `processNext`. |

**Note.** A nested plain `async` helper drops the mutation that runs after its await and
replies with the inner value. An earlier revision of `Redemption.mo` contained that pattern,
which would have discarded the `busy[i] := false` release; it was corrected before this
audit. Finding R-2 concerns the same release failing through a different mechanism (a reject
rather than a nesting bug). The line has therefore been broken by two unrelated causes, and
both are covered by regression tests.

### 1.4 Build and packaging

| Rule | Disposition |
|---|---|
| Never set `"optimize"` in `dfx.json` on a Motoko EOP canister, and it produces a *bigger* binary behind a green log | **CLEAN**, `dfx.json` sets no `optimize`. Do not add one. |
| `dfx.json` must not pass `--package core`, dfx supplies it | **CLEAN**, and improved: `dfx.json` now carries no `args` at all and uses `packtool: "mops sources"`. |
| Dependencies pinned | **FIXED THIS SESSION.** The repo previously had no `mops.toml` and reached into `/menese/.mops` by absolute path: a build input outside the repository, unpinned and unrecorded. Now `mops.toml` + `mops.lock` pin `core@2.4.0` and `sha2@0.1.9` with 62 file hashes. |

---

## 2. Reproducible build, measured, and one rule narrowed

`verification/verify-build.sh`, **6/6**.

```
moc 1.4.1                                          ok
core@2.4.0, sha2@0.1.9 resolve from mops.lock      ok
md5 == 8196485adbba80dade277961d2436a32            ok
two consecutive builds byte-identical              ok
build from a DIFFERENT directory byte-identical    ok
```

The last line is the one that matters. A module that only reproduces in its own directory is
*repeatable*, not reproducible, and that distinction has cost real time before.

### The correction

The widely-held rule is that moc
derives the `Entry__449410820` type disambiguators from **absolute** paths, so reproducing a
module requires pinning the checkout directory, every `.mops/<pkg>@<ver>/`, and the untracked
`.mops/moc-<hash>/`. That rule is right about the mechanism and too broad about its reach.

Measured here, three builds differing in one input each:

| build | md5 |
|---|---|
| relative source + relative packages | `8196485adbba80dade277961d2436a32` |
| relative source + **absolute** packages | `8196485adbba80dade277961d2436a32`, identical |
| **absolute** source + relative packages | `29b6fb36f0fcc832d872076f2e013477`, differs |

The disambiguator follows the path of the file **defining** each stable type, as moc is given
it. Every stable type here, `Entry`, `Payout`, `Progress`, `Source`, `Status`, is defined in
`src/Types.mo`, and none comes from a dependency. So the package paths cannot enter the hash,
and passing the entry source relatively makes the module path-independent: byte-identical from
three directories.

That rule remains correct for canisters whose stable types come from dependencies. It stops
applying when every stable type is local. **The
practical consequence is better than the rule suggested: pass relative paths and this module
reproduces anywhere, without a pinned mount point.**

The pinned image (`docker/`) remains useful, because moc's *code generation* is
version-sensitive even when the paths are not. It pins the toolchain, not the directory.

⚠️ **This property is a fact about today's source, not a guarantee.** The moment a stable
type is imported from a package, the absolute `.mops/` path re-enters the hash and the mount
point matters again. `verify-build.sh` check 5 is what will notice.

---

## 3. Class sweep

Every class gets a disposition.

**Arithmetic and money.** Single 8-decimal token; no cross-decimal arithmetic anywhere.
`liquidPayable` tests `amount > fee`, gross against the fee, correct because ICRC-1 debits
the fee from the sender. `payoutAmount` rounds a neuron stake up to `MIN_NEURON_STAKE_E8S`.
`Nat` subtraction appears only in `unwind`, always against a value added earlier in the same
message, so it cannot underflow. One unchecked narrowing survives at `Redemption.mo:326`,
`Nat32.fromNat(Nat64.toNat(add))`: every `delaySeconds` in the frozen table is far below 2³²,
so it cannot trap on this table, **noted, not filed, and it depends on the table being what
it is believed to be, which is the snapshot question again.**

**Authority.** No admin, no mint, no method that adds/edits/removes an entry or moves the
reserve anywhere but to an entry's own payout. `setNeuronDestination` is gated on
`entries[i].owner == caller` and cannot be exercised on anyone else's entry. Anonymous
callers are rejected from nomination. `verifyParameters` sets a flag only when live
governance agrees, so its openness is harmless. **CLEAN.**

**Idempotency and commit points.** This was the failing class and is the one that got the
most work. Status is written before the call it guards; a definite `#Err` unwinds; a
**reject** now unwinds too; `#Duplicate` counts as paid; a `#TooOld` dedup window is marked
ambiguous rather than guessed. `#Duplicate` is only reachable because the transfer carries a
deterministic `created_at_time` and memo, without which a rollback-and-retry is a
double-spend. **FIXED, with a live regression test.**

**Liveness.** `nextStep` skips entries awaiting a destination so one un-nominated staker
cannot park the queue; the driver backs off exponentially while failing and clears the
backoff on the first success, so recovery needs no operator and no new authority.

**Bounds.** Every walk is over `entries`, fixed in size at install. No caller supplies a
collection, no batch endpoint exists, nothing appends to persistent state. **CLEAN.**

**Checks that do not check.** The battery traps on any failure, so a failure count cannot be
computed and discarded. Twelve injected defects, twelve caught. Two vacuity traps were found
and fixed by this project rather than assumed absent: the absolute-vs-additive dissolve delay
control passed vacuously until a forced retry existed, and `settled` was unfalsifiable:
`failed == 0` made it false forever on any real table, until the rename. **The habit of
re-testing the test is the strongest thing about this suite.**

**Privacy.** `myEntries` is correctly caller-scoped. `getTable` is deliberately public and is
finding R-7. No cryptographic privacy claim is made anywhere, which is right, and there is none.

---

## 4. What is open

**R-6: the drive methods are unauthenticated and uncapped.** Ingress is paid by the
canister. Restricting who may call `process`/`processNext` would remove the deliberate
property that anyone can drive a wedged timer; whether to keep that property is a
governance decision, not a code change. The real
mitigation is a **named owner for cycle monitoring**, which is the operational consequence of
choosing never to blackhole. There is currently no owner.

**R-7, `getTable()` publishes every holder's principal and amount.** Deliberate, and
probably right: public verifiability of the eligible set is the point. But it contradicts
the way the table is handled off-chain, where the design tree is kept out of any
repository *because it contains the holder table with principals*. Both cannot be the
operative privacy posture, and holders should be told
their principal and balance become permanently public and linkable.

**The snapshot pipeline has never been audited.** The snapshot builder, the block freeze,
and the disjointness assertion live outside this repository. A defect
there writes a wrong table into a constructor argument that **no method in this canister can
ever correct**: the immutability that is the canister's main safety property is also what
makes a bad input permanent. Every "CLEAN" above is conditional on the table being right, and
nothing in this repository can establish that.

That pass should happen before the table is compiled in, and it is the last thing between
this canister and any named deployment.

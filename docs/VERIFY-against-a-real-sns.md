# Verification against deployed SNS modules

Module under test: `7dd8a3d10c70929d6fbcc55dd1284c80`, 780050 bytes: the artifact
`build/redemption.wasm` holds and `verification/verify-build.sh` reproduces. Run 2026-09-09.

**41 checks, 0 failures.**

## Method

An SNS is launched from `sns_init.yaml` by submitting a `CreateServiceNervousSystem`
proposal to the **mainnet NNS Governance module**, adopting it, opening and filling the swap,
and finalizing. `build/redemption.wasm` is then installed alongside it and the payout path is
driven against the **mainnet SNS Governance module** and the **mainnet Rust ICRC-1 ledger**.

No SNS rule is reimplemented; every result is read from the deployed canisters. The tokens
paid out are tokens that SNS minted, obtained by disbursing a swap participant's basket
neuron.

The seventeen NNS and SNS modules are each verified twice on fetch: sha256 against the
pinned manifest, and against the module hash the IC itself reports. The provenance record is
kept with the SNS launch configuration, outside this repository.

## Scope

Mock-based suites verify behaviour against a model of the counterparty; a divergence between
that model and the deployed counterparty is outside what they can establish. This run exists
to close that gap for the payout path. Defect F-1
(`docs/FINDING-grantable-permissions.md`) is an instance of exactly that class.

## The table under test

Five entries. Entry 4 is deliberately positioned behind both neuron entries.

| # | holder | amount | payout | expected |
|---|---|---:|---|---|
| 0 | A | 5 MENES | Liquid | paid |
| 1 | B | 0.00005 MENES | Liquid | `Failed`, at or below the fee |
| 2 | C | 20 MENES | Neuron, 26 weeks | neuron to C's **nominated** principal |
| 3 | D | 10 MENES | Neuron, 18 months | neuron to D's **nominated** principal, driven only by the timer |
| 4 | E | 2 MENES | Liquid | paid even while entries 2 and 3 are stalled |

## Results

### Our constants against the live SNS

| | | |
|---|---|---|
| `S1` | live voting floor = compiled-in `DISSOLVE_FLOOR_SECONDS` | `15724800` |
| `S2` | live minimum neuron stake = compiled-in `MIN_NEURON_STAKE_E8S` | `1000000000` |
| `S3` | live transfer fee = compiled-in `FEE_E8S` | `10000` |

Live `neuron_grantable_permissions` = `[0,1,2,3,4,5,6,7,8,9,10]`, **eleven**, not twelve.

### The canister

| | | |
|---|---|---|
| `C1` | `verifyParameters()` against real governance | `ok("floor ok: configured 15724800s >= live 15724800s")` |
| `C2` | a neuron entry does nothing before its owner nominates | `ok("awaiting a destination from the owner")` |
| `C3` | a principal with no neuron entry cannot nominate | `err("no unpaid neuron entry belongs to you")` |
| `C4` | each owner nominates their own destination | `ok(1)`, `ok(1)` |

`C1` settles a question a mock could not: the `.did` declares
`get_nervous_system_parameters : (null) -> ...`, one argument, while the Motoko import
declares none. The deployed canister accepts the call.

### Audit R-3, against a genuinely rejecting ledger

The SNS ledger canister is **stopped**, not a mock trained to trap.

| | | |
|---|---|---|
| `C5a` | `process(0)` reports failure, does not trap | `err("transfer rejected: … is stopped")` |
| `C5b` | entry 0 is **not** marked `Done` by the rejection | `Pending` |
| `C5c` | the error is recorded, not lost | present |
| `C5d` | `created_at_time` fixed on the first attempt | `1622376122000000233` |
| `C6a` | after restart, entry 0 reaches `Done` | `Done` |
| `C6b` | holder A credited exactly the entry amount, once | `500000000` |

This is the critical audit finding reproduced end to end on the real ledger: before the fix,
a rejecting ledger marked the entry `Done` while paying nobody, irreversibly.

### The neuron path

`entry 2 log: funded → claimed → delay set → granted to holder → done`

| | entry 2 | entry 3 |
|---|---|---|
| status | `Done` | `Done`, **driven only by the canister's own 15-second timer** |
| neuron id = IC staking-subaccount formula | `a07c6623…` ✓ | `7e71cd6d…` ✓ |
| dissolve delay off real governance | `15724800` | `47260800` |
| stake off real governance | `2000000000` | `1000000000` |
| nominated destination's permissions | `[0…10]` | `[0…10]` |
| snapshot owner's permissions | none | none |
| redemption canister's permissions | none | none |

The dissolve delays being exact to the second is what proves `IncreaseDissolveDelay` is
additive on the real canister and that the canister sends the difference rather than the
absolute value. The neuron id matching a reimplementation of the IC's own formula, written
in the harness from `rs/nervous_system/common/src/ledger.rs`, not from `src/Logic.mo`, is a
third independent check of the subaccount derivation.

The last two rows are the property the whole design rests on: the holder controls the neuron
outright, the principal from the snapshot does not, and the canister that created it has
removed itself.

### Driver fairness

SNS Governance is stopped, so both neuron entries fail at the claim step on every attempt.
Entry 4 sits behind them and needs only the ledger.

| | | |
|---|---|---|
| `C17a` | entries 2 and 3 are stalled while governance is down | `Funded` / `Funded` |
| `C17b` | entry 4, behind both, still reaches `Done` | `Done` |
| `C17c` | entry 4 was credited its full amount | `200000000` |
| `C17d` | `settlement()` names the stalled entry | `entry 2 has failed 11 consecutive attempt(s)` |

Under a driver that restarts its scan at index 0 on every pass, entry 4 is never attempted.

### The books

| | | |
|---|---|---|
| `C7` | dust below the fee is `Failed`, not silently skipped | `"amount 5000 is at or below the ledger fee; unpayable"` |
| `C15a` | `reconcile()` holds | reserve `15_000` = expected `15_000` |
| `C15b` | `reconcile()`'s reserve balance is the ledger's own number | `15000` |
| `C16a` | `settlement()` settled | `"every entry resolved, books balance; 1 written off as unpayable"` |
| `C16b` | writes off exactly the one dust entry | `1` |

### The ledger properties the retry safety rests on

Exercised directly on the real Rust ICRC-1 ledger.

| | | |
|---|---|---|
| `L1a` | the first transfer is accepted | block `419` |
| `L1b` | a byte-identical replay returns `Duplicate` | `Duplicate { duplicate_of: 419 }` |
| `L1c` | the target was credited exactly once | `1000000` |
| `L2` | a `created_at_time` outside the window returns `TooOld` | `TooOld` |

These are ledger-level, not canister-level. PocketIC cannot drop a reply, so the case of a
transfer that lands with its reply lost cannot be induced end to end. What is established is that
the ledger really does behave the way the canister assumes when it fixes `created_at_time`
on the first attempt and reuses it on every retry. The canister's handling of both answers
is covered by `test/repro-reject.sh`.

## What this run does not establish

- **The table.** The snapshot pipeline produces it, and it lives outside this repository and
  has never been audited. Every result above is conditional on the table being right, and no
  method on this canister can correct it once installed.
- **Scale.** Four entries, not a full table. Nothing here measures cycles or instruction counts over
  the real table.
- **An upgrade.** Adding `txTime` to `Progress` after install is a compatibility question,
  and `moc --stable-compatible` is the gate for it. This harness installs fresh.
- **R-6 and R-7**, which remain decisions for the maintainers, not code.

## Reproducing

```sh
cp verification/pocketic/menese_redemption_sim.rs \
   <ic-checkout>/rs/nervous_system/integration_tests/tests/
verification/pocketic/run_redemption_sim.sh build/redemption.wasm
```

`verification/pocketic/README.md` explains the assets, the one source change needed in the
`ic` checkout, and what each check is for.

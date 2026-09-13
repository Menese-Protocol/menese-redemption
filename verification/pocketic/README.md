# PocketIC harness, verification against deployed SNS modules

`test/e2e.sh` and `test/repro-reject.sh` verify the canister against `test/MockLedger.mo`
and `test/MockGov.mo`. Those mocks encode a model of the ICRC-1 ledger and SNS Governance.
A divergence between that model and the deployed counterparty is outside what they can
establish, regardless of how many checks pass. Defect F-1
(`docs/FINDING-grantable-permissions.md`) is a recorded instance of that class.

This harness closes the gap for the payout path. It launches an SNS by submitting a
`CreateServiceNervousSystem` proposal to mainnet NNS Governance, running a swap and
finalizing. It then installs `build/redemption.wasm` alongside it, funds the reserve with tokens that SNS
minted, and drives the payout path against the mainnet SNS Governance module and the
mainnet Rust ICRC-1 ledger. No SNS rule is reimplemented here.

## Running it

The harness is a test in the `dfinity/ic` monorepo, because that is where the integration
test helpers and the mainnet-module fetcher live. It is kept here as well so it is not
orphaned in a worktree.

Three inputs are needed, and the runner takes them as environment variables rather than
assuming any particular machine layout.

| | |
|---|---|
| `IC_CHECKOUT` | a `dfinity/ic` checkout at the revision the modules were fetched against, `065e2817` |
| `SIM_ASSETS` | a directory holding `bin/pocket-ic-server` and `wasms-mainnet/*.wasm.gz` |
| `SNS_INIT_YAML` | the `sns_init.yaml` to launch |

```sh
# graft the test into the ic checkout
cp verification/pocketic/menese_redemption_sim.rs \
   "$IC_CHECKOUT/rs/nervous_system/integration_tests/tests/"

# run it
SIM_ASSETS=... IC_CHECKOUT=... SNS_INIT_YAML=... \
  verification/pocketic/run_redemption_sim.sh build/redemption.wasm
```

`SIM_ASSETS/wasms-mainnet/` holds the seventeen NNS and SNS modules, each verified twice
when fetched: sha256 against the pinned manifest, and against the module hash the IC itself
reports, `dfx canister info --network ic` for the NNS canisters, and for the six SNS
modules the version SNS-W publishes as the one a newly created SNS is deployed with. The
provenance table is kept with the SNS launch configuration, outside this repository. The
modules can be re-fetched from scratch by anyone with a mainnet `dfx`; nothing here depends
on trusting a local copy.

One source change is needed in the `ic` checkout:
`ic_sns_cli::read_create_service_nervous_system_from_init_yaml` must be made public, so the
test consumes the same yaml conversion the `sns` CLI does.

## What each check is for

Checks are named so that a failure identifies the property that broke.

| | |
|---|---|
| `S1`-`S3` | compiled-in constants against the live nervous system parameters |
| `C1` | `get_nervous_system_parameters` accepts the call: the `.did` declares one `null` argument where the Motoko import declares none |
| `C2`-`C4` | the destination nomination, including that a non-owner cannot nominate |
| `C5` | audit R-3 against a rejecting ledger: the SNS ledger canister is **stopped**, rather than a mock configured to trap |
| `C6` | after recovery, the holder is credited exactly once |
| `C7` | dust below the fee is written off visibly |
| `C8` | the five-step neuron path completes; entry 3 is left to the canister's own timer |
| `C9`/`C10` | stake, and dissolve delay exact to the second, which is what proves `IncreaseDissolveDelay` is additive and that the canister sends the difference |
| `C9b`-`C9e` | the permission model: the nominated destination controls the neuron, the snapshot owner does not, and the canister has stripped itself |
| `C9d`/`C10d` | the neuron id governance minted equals the IC's staking-subaccount formula, reimplemented in the harness from the IC source |
| `C17` | driver fairness: SNS Governance is **stopped**, both neuron entries stall, and the liquid entry behind them must still be paid |
| `C15`/`C16` | `reconcile()` against the ledger's own balance, and `settlement()` |
| `L1`/`L2` | ICRC-1 deduplication and the transaction window on the real Rust ledger |

## What it does not cover

`L1`/`L2` are ledger-level property checks, not end-to-end canister ones. The canister's
retry safety depends on the case of a transfer that lands with its reply lost, and PocketIC
cannot drop a reply, so that interleaving cannot be induced here. What the harness
establishes is that the deployed ledger behaves as the canister assumes when it fixes
`created_at_time` on the first attempt and reuses it: a byte-identical replay returns
`Duplicate`, and one outside the window returns `TooOld`. The canister's handling of both
answers is covered by `test/repro-reject.sh`.

The snapshot pipeline that produces the table is out of scope here and has not been
audited. Every result in this harness is conditional on the table being correct.

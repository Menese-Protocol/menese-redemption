# PocketIC harness, verification against deployed SNS modules

Mocks encode a model of their counterparties. A divergence between that model and the
deployed module is outside what they can establish, regardless of how many checks pass.
Defect F-1 (`docs/FINDING-grantable-permissions.md`) is a recorded instance of that class.

This harness closes the gap. On PocketIC, with the modules live on mainnet, it replays the
MENES ledger's history on the real MENES ledger module, launches the SNS from
`sns_init.yaml` through a `CreateServiceNervousSystem` proposal to NNS Governance, runs the
swap and finalizes it. The holder canister then binds, takes the snapshot, builds the table
and delivers every share by itself, against the mainnet SNS Governance and ledger modules,
with no DAO proposal. No SNS rule is reimplemented here.

A second harness, `menese_redemption_mocks.rs`, runs the same module against
failure-injecting mocks (groups B, H, F, R, Q, D, G: binding, the happy path, fail-closed
checks, resume after every fault, the books and the holder-first schedule, delivery rules,
secret split memos and a neuron another principal holds at a part's id). It is what
`verification/planted-faults.sh` runs.

## Running it

The harness is a test in the `dfinity/ic` monorepo, because that is where the integration
test helpers and the mainnet-module fetcher live. It is kept here as well so it is not
orphaned in a worktree.

Besides the MENES worlds (from `verification/real_world.py`), the runner takes its inputs
as environment variables rather than assuming any machine layout.

| | |
|---|---|
| `IC_CHECKOUT` | a `dfinity/ic` checkout |
| `SIM_ASSETS` | a directory holding `bin/pocket-ic-server` and `wasms-mainnet/*.wasm.gz` |
| `MODULES_DIR` | optional: another directory of NNS and SNS modules |
| `REGISTRY_WASM` | optional: a registry module to use instead of the one in the module directory |
| `SNS_INIT_YAML` | the `sns_init.yaml` to launch |
| `HOLDER_CANISTER` | the holder canister's id, as `sns_init.yaml` lists it among the dapp canisters |
| `MENES_LEDGER_WASM` | the MENES ledger module |

```sh
# graft the test into the ic checkout
cp verification/pocketic/menese_redemption_sim.rs \
   "$IC_CHECKOUT/rs/nervous_system/integration_tests/tests/"

SIM_ASSETS=... IC_CHECKOUT=... SNS_INIT_YAML=... HOLDER_CANISTER=... MENES_LEDGER_WASM=... \
  verification/pocketic/run_redemption_sim.sh <world.txt> [synthetic-world.txt] build/redemption.wasm
```

`SIM_ASSETS/wasms-mainnet/` (or `MODULES_DIR`) holds the NNS and SNS modules, the cycles
minting canister included, each verified twice
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
`docs/VERIFY-against-a-real-sns.md` records the latest run, check by check.

| | |
|---|---|
| `L1`, `L2` | the MENES history replayed on the real ledger module; the supply after it |
| `G0`-`G2` | the holder canister at its id, its nine genesis neurons, unbound during the swap |
| `S1`-`S5` | the binding; the snapshot; the table hash, every row and the list of holders left out equal to the off-chain builder's |
| `D1`, `D2` | nominations; every share delivered through upgrades by SNS root |
| `N1`, `N2` | every neuron read back from governance: rung, owner, permissions, stake, delay; no holder, destination or holder left out holds liquid MPV |
| `B1`-`B5` | the books to the e8s, the canister's own counts, settlement, no neuron left, zero proposals |

Each id is prefixed `R` on the real MENES history and `S` on the synthetic world.

## What runs elsewhere

PocketIC cannot drop a reply. The lost-reply, reject and error cases at every command on
every genesis neuron, ledger and sale-canister rejects during the snapshot, and an upgrade
between every two steps are driven against the mocks (`menese_redemption_mocks.rs`, group R).

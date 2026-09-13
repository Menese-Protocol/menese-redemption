#!/usr/bin/env bash
# Run the redemption canister against a real SNS on PocketIC.
#
# The NNS and SNS modules used here are the byte-identical WASMs live on mainnet. Each was
# verified twice when fetched: sha256 against the pinned manifest, and against the module
# hash the IC itself reports (`dfx canister info --network ic`, and for the six SNS modules
# the version SNS-W publishes as the one a new SNS is deployed with).
#
# Usage:
#   SIM_ASSETS=<dir> IC_CHECKOUT=<dir> run_redemption_sim.sh [path/to/redemption.wasm]
#
#   SIM_ASSETS    directory holding bin/pocket-ic-server and wasms-mainnet/*.wasm.gz
#   IC_CHECKOUT   a dfinity/ic checkout with menese_redemption_sim.rs grafted into
#                 rs/nervous_system/integration_tests/tests/
#   SNS_INIT_YAML the sns_init.yaml to launch
#
# See README.md in this directory for how to populate SIM_ASSETS.
set -euo pipefail

SIM_ASSETS="${SIM_ASSETS:?set SIM_ASSETS to the directory holding bin/ and wasms-mainnet/}"
IC_CHECKOUT="${IC_CHECKOUT:?set IC_CHECKOUT to a dfinity/ic checkout}"
SNS_INIT_YAML="${SNS_INIT_YAML:?set SNS_INIT_YAML to the sns_init.yaml to launch}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REDEMPTION="${1:-$REPO_ROOT/build/redemption.wasm}"

# The run cd's into IC_CHECKOUT, so every path handed to the test must be absolute first.
[ -f "$REDEMPTION" ] || { echo "no such module: $REDEMPTION" >&2; exit 1; }
REDEMPTION="$(cd "$(dirname "$REDEMPTION")" && pwd)/$(basename "$REDEMPTION")"
SIM_ASSETS="$(cd "$SIM_ASSETS" && pwd)"
SNS_INIT_YAML="$(cd "$(dirname "$SNS_INIT_YAML")" && pwd)/$(basename "$SNS_INIT_YAML")"

W="$SIM_ASSETS/wasms-mainnet"
[ -d "$W" ] || { echo "no such asset directory: $W" >&2; exit 1; }

# NNS canisters, mainnet modules
export MAINNET_REGISTRY_CANISTER_WASM_PATH="$W/registry.wasm.gz"
export MAINNET_GOVERNANCE_CANISTER_WASM_PATH="$W/governance.wasm.gz"
export MAINNET_ICP_LEDGER_CANISTER_WASM_PATH="$W/ledger.wasm.gz"
export MAINNET_ROOT_CANISTER_WASM_PATH="$W/root.wasm.gz"
export MAINNET_LIFELINE_CANISTER_WASM_PATH="$W/lifeline.wasm.gz"
export MAINNET_SNS_WASM_CANISTER_WASM_PATH="$W/sns-wasm.wasm.gz"
export MAINNET_NODE_REWARDS_CANISTER_WASM_PATH="$W/node-rewards.wasm.gz"

# SNS canisters, the versions SNS-W publishes for a newly created SNS
export MAINNET_SNS_ROOT_CANISTER_WASM_PATH="$W/sns_root.wasm.gz"
export MAINNET_SNS_GOVERNANCE_CANISTER_WASM_PATH="$W/sns_governance.wasm.gz"
export MAINNET_SNS_SWAP_CANISTER_WASM_PATH="$W/swap.wasm.gz"
export MAINNET_IC_ICRC1_LEDGER_WASM_PATH="$W/sns_ledger.wasm.gz"
export MAINNET_IC_ICRC1_ARCHIVE_WASM_PATH="$W/sns_archive.wasm.gz"
export MAINNET_IC_ICRC1_INDEX_NG_WASM_PATH="$W/sns_index.wasm.gz"

export POCKET_IC_BIN="$SIM_ASSETS/bin/pocket-ic-server"

export MENESE_SNS_INIT_YAML="$SNS_INIT_YAML"
export MENESE_REDEMPTION_WASM="$REDEMPTION"
export MENESE_REPORT_JSON="${MENESE_REPORT_JSON:-$REPO_ROOT/build/redemption-sim-report.json}"
mkdir -p "$(dirname "$MENESE_REPORT_JSON")"

export RUST_BACKTRACE=1

echo "module   : $REDEMPTION"
echo "md5      : $(md5sum "$REDEMPTION" | cut -d' ' -f1)"
echo "init yaml: $MENESE_SNS_INIT_YAML"

cd "$IC_CHECKOUT"
exec cargo test --release --test menese_redemption_sim -p ic-nervous-system-integration-tests \
    -- --nocapture --test-threads=1

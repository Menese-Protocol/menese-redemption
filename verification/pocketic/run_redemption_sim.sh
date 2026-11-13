#!/usr/bin/env bash
# Run the holder canister against the real SNS on PocketIC: the MENES ledger module at its
# own id with its history replayed, the SNS launched from sns_init.yaml with the holder
# canister's nine genesis neurons, the swap, the snapshot, and delivery of every share, with
# no DAO proposal. See README.md in this directory.
#
# Usage:
#   SIM_ASSETS=<dir> IC_CHECKOUT=<dir> SNS_INIT_YAML=<file> HOLDER_CANISTER=<id> \
#   MENES_LEDGER_WASM=<file> run_redemption_sim.sh <world.txt> [synthetic-world.txt] [redemption.wasm]
#
#   SIM_ASSETS        directory holding bin/pocket-ic-server
#   MODULES_DIR       the NNS/SNS module directory (default: $SIM_ASSETS/wasms-mainnet)
#   REGISTRY_WASM     optional: a registry module to use instead of the one in MODULES_DIR
#   IC_CHECKOUT       a dfinity/ic checkout with menese_redemption_sim.rs in
#                     rs/nervous_system/integration_tests/tests/
#   SNS_INIT_YAML     the sns_init.yaml to launch
#   HOLDER_CANISTER   the holder canister's id, as sns_init.yaml lists it
#   MENES_LEDGER_WASM the MENES ledger module
#   MOCKS_DIR         the built test modules (default: build/test)
#   REPORT_JSON       optional: where to write the per-check report
#
# world.txt comes from verification/real_world.py (replay or synthetic).
set -euo pipefail
SIM_ASSETS="${SIM_ASSETS:?}"; IC_CHECKOUT="${IC_CHECKOUT:?}"; SNS_INIT_YAML="${SNS_INIT_YAML:?}"
HOLDER_CANISTER="${HOLDER_CANISTER:?}"; MENES_LEDGER_WASM="${MENES_LEDGER_WASM:?}"
WORLD=${1:?usage: run_redemption_sim.sh <world.txt> [synthetic-world.txt] [redemption.wasm]}
SYNTHETIC=${2:-}
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
abs(){ echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
HOLDER_WASM="$(abs "${3:-$REPO_ROOT/build/redemption.wasm}")"
MOCKS="$(cd "${MOCKS_DIR:-$REPO_ROOT/build/test}" && pwd)"
W="${MODULES_DIR:-$SIM_ASSETS/wasms-mainnet}"
[ -d "$W" ] || { echo "no such module directory: $W" >&2; exit 1; }

export MAINNET_REGISTRY_CANISTER_WASM_PATH="${REGISTRY_WASM:-$W/registry.wasm.gz}"
export MAINNET_GOVERNANCE_CANISTER_WASM_PATH="$W/governance.wasm.gz"
export MAINNET_ICP_LEDGER_CANISTER_WASM_PATH="$W/ledger.wasm.gz"
export MAINNET_ROOT_CANISTER_WASM_PATH="$W/root.wasm.gz"
export MAINNET_LIFELINE_CANISTER_WASM_PATH="$W/lifeline.wasm.gz"
export MAINNET_SNS_WASM_CANISTER_WASM_PATH="$W/sns-wasm.wasm.gz"
export MAINNET_NODE_REWARDS_CANISTER_WASM_PATH="$W/node-rewards.wasm.gz"
export MAINNET_CYCLES_MINTING_CANISTER_WASM_PATH="$W/cycles-minting.wasm.gz"
export MAINNET_SNS_ROOT_CANISTER_WASM_PATH="$W/sns_root.wasm.gz"
export MAINNET_SNS_GOVERNANCE_CANISTER_WASM_PATH="$W/sns_governance.wasm.gz"
export MAINNET_SNS_SWAP_CANISTER_WASM_PATH="$W/swap.wasm.gz"
export MAINNET_IC_ICRC1_LEDGER_WASM_PATH="$W/sns_ledger.wasm.gz"
export MAINNET_IC_ICRC1_ARCHIVE_WASM_PATH="$W/sns_archive.wasm.gz"
export MAINNET_IC_ICRC1_INDEX_NG_WASM_PATH="$W/sns_index.wasm.gz"
export POCKET_IC_BIN="$SIM_ASSETS/bin/pocket-ic-server"
export MENESE_SNS_INIT_YAML="$(abs "$SNS_INIT_YAML")" MENESE_HOLDER_CANISTER="$HOLDER_CANISTER"
export MPV_HOLDER_WASM="$HOLDER_WASM" MPV_HOLDER_MOCKS_DIR="$MOCKS" MENES_LEDGER_WASM="$(abs "$MENES_LEDGER_WASM")"
export MENESE_WORLD="$(abs "$WORLD")"
[ -n "$SYNTHETIC" ] && export MENESE_SYNTHETIC_WORLD="$(abs "$SYNTHETIC")"
[ -n "${REPORT_JSON:-}" ] && { mkdir -p "$(dirname "$REPORT_JSON")"; export MPV_REPORT_JSON="$(abs "$REPORT_JSON")"; }
export RUST_BACKTRACE=1
echo "holder canister module: sha256 $(sha256sum "$HOLDER_WASM" | cut -d' ' -f1)"
echo "MENES ledger module:    sha256 $(sha256sum "$MENES_LEDGER_WASM" | cut -d' ' -f1)"
cd "$IC_CHECKOUT"
exec nice -n 10 cargo test --release --test menese_redemption_sim -p ic-nervous-system-integration-tests \
    -- --nocapture --test-threads=1

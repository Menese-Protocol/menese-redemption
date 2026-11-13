# Build and verify

The canister builds from this repository alone. Dependencies are pinned by `mops.lock`
(`core@2.4.0`, `sha2@0.1.9`, 62 file hashes); nothing resolves outside the checkout.

```sh
mops install

# 1. pure-logic battery, no replica (188 checks)
moc -r $(mops sources) test/run_tests.mo

# 2. the canister
moc -o build/redemption.wasm $(mops sources) src/Redemption.mo

# 3. the test modules (mocks at the MENES ledger, sale canister and SNS-W ids)
for m in MockSns MockMenesLedger MockSale Proxy; do
  moc -o build/test/$m.wasm $(mops sources) test/$m.mo
done

# 4. against failure-injecting mocks on PocketIC (groups B H F R Q D G; 93 checks).
#    Built and run from a dfinity/ic checkout; see verification/pocketic/README.md.
POCKET_IC_BIN=... MPV_HOLDER_WASM=build/redemption.wasm MPV_HOLDER_MOCKS_DIR=build/test \
MPV_HOLDER_WORLD=<verification/mock_world.py output> <menese_redemption_mocks test binary>

# 5. against the deployed NNS and SNS modules and the real MENES ledger history (42 checks)
SIM_ASSETS=... IC_CHECKOUT=... SNS_INIT_YAML=... HOLDER_CANISTER=... MENES_LEDGER_WASM=... \
  verification/pocketic/run_redemption_sim.sh <world.txt> [synthetic-world.txt] build/redemption.wasm

# 6. negative controls: each named defect must turn its test red
MOCKS_BIN=... MOCKS_WORLD=... POCKET_IC_BIN=... ./verification/planted-faults.sh <scratch dir>
```

Steps 1 to 4 and 6 are mock-driven. Step 5 uses the deployed modules and establishes what
the mocks cannot (`docs/VERIFY-against-a-real-sns.md`).

## Reproducibility

```sh
./verification/verify-build.sh     # 6/6
```

Checks the toolchain, the lockfile, the recorded md5, that two consecutive builds agree,
and that a build **from a different directory** is byte-identical. A
module that only reproduces in its own directory is repeatable, not reproducible.

**Pass the entry source as a RELATIVE path.** moc derives the `Entry__449410820` type
disambiguators in `motoko:stable-types` from the path of the file *defining* each stable
type, as moc is given it. Every stable type here lives in `src/Types.mo` and none comes from
a dependency, so package paths cannot enter the hash and a relative source makes the module
path-independent. Measured:

| build | md5 |
|---|---|
| relative source + relative packages | `8196485adbba80dade277961d2436a32` |
| relative source + **absolute** packages | `8196485adbba80dade277961d2436a32` |
| **absolute** source + relative packages | `29b6fb36f0fcc832d872076f2e013477` |

(Measured on the 2026-09-08 module. The conclusion is about paths, not about that module's
contents, and check 5 of the verifier re-establishes it on every run.)

This is narrower than the widely-held rule, which says absolute paths are baked in and the
mount point must be pinned. That rule is correct for canisters whose stable types come from
dependencies; it stops applying when every stable type is local. If one is ever imported
from a package the absolute `.mops/` path re-enters the hash, and check 5 of the verifier is
what notices.

`docker/` pins the toolchain for anyone who wants a hermetic build. It pins moc and dfx,
whose code generation is version-sensitive; it does not need to pin the directory.

Reference build: `302cdaedb94bd4cdb163421928c8e71d`, 1,149,774 bytes, sha256
`d3c818b5e07d9945b63d6ea57a457338a0cd5f3acd72d07be0b3ac6833174b20`. Neurons only, with
secret split memos: a part's memo comes from a seed the canister draws from the IC's
randomness and never returns, and a neuron found at a part's id before its split is
reported and never taken as the part. Supersedes `83dade70cfdd9078b614f4b1ded2ca6b` /
1,135,142 bytes (neurons only, with public split memos), which superseded
`299cb743622774dcf7e0fbcacfee0103` / 1,148,593 bytes (the genesis-neuron design with liquid
payments), which superseded `aefb507c82caa69d4c9bddf37b7b14a6` / 818,206 bytes (the
nine-neuron basket funded from a reserve), which superseded `7dd8a3d10c70929d6fbcc55dd1284c80` / 780,050 bytes
and `8196485adbba80dade277961d2436a32` / 756,044 bytes, the module defect F-1 was present in.

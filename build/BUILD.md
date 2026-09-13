# Build and verify

The canister builds from this repository alone. Dependencies are pinned by `mops.lock`
(`core@2.4.0`, `sha2@0.1.9`, 62 file hashes); nothing resolves outside the checkout.

```sh
mops install

# 1. pure-logic battery, no replica
moc -r $(mops sources) test/run_tests.mo

# 2. the canister
moc -o build/redemption.wasm $(mops sources) src/Redemption.mo

# 3. end to end against mock ledger + mock governance on a local replica
dfx start --clean --background --host 127.0.0.1:8973
./test/e2e.sh

# 4. the audit regression: a ledger that REJECTS rather than returning an error.
#    Needs its own clean replica; it deploys the same canister ids.
dfx stop && rm -rf .dfx && dfx start --clean --background --host 127.0.0.1:8973
./test/repro-reject.sh

# 5. driver fairness: a permanently-failing entry must not starve the entries behind it.
dfx stop && rm -rf .dfx && dfx start --clean --background --host 127.0.0.1:8973
./test/fairness.sh

# 6. against the deployed SNS Governance and Rust ICRC-1 ledger modules, on PocketIC.
#    See verification/pocketic/README.md for what this covers.
SIM_ASSETS=... IC_CHECKOUT=... SNS_INIT_YAML=... \
  verification/pocketic/run_redemption_sim.sh build/redemption.wasm
```

Steps 1 to 5 are mock-driven: the counterparties are `test/MockLedger.mo` and
`test/MockGov.mo`, which encode a model of the ledger and of SNS Governance. Step 6 uses the
deployed modules and establishes what the model cannot. Run it before any deploy.

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

Reference build: `7dd8a3d10c70929d6fbcc55dd1284c80`, 780050 bytes.
Supersedes `8196485adbba80dade277961d2436a32` / 756044 bytes, which is the module the
defect F-1 was present in.

Note for anyone reproducing an older hash: moc emits doc comments on Candid-visible
declarations into the module's embedded interface, so editing one of those produces a
distinct module even though no behaviour changed. Plain `//` comments do not. A
documentation pass is therefore re-verified like any other change.

| Suite | Result |
|---|---|
| Pure logic battery | 130 checks, 0 failures |
| End to end on a replica | 27 checks, 0 failures |
| Reject regression (audit R-1/R-2/R-3) | 15 checks, 0 failures |
| Driver fairness | 9 checks, 0 failures |
| **PocketIC, deployed SNS modules** | **41 checks, 0 failures** |
| Negative controls | 14 injected defects, 14 caught |

Negative controls run: 180-day floor; backwards state transition; little-endian nonce;
liquid routed into the neuron path; dust below the fee marked payable; absolute instead of
additive dissolve delay; a neuron paying out with no destination nominated; a neuron sent to
the snapshot principal in spite of a nomination; and three on `settled`: the old
`failed == 0` rule (3 checks fail), the reconciliation term dropped (1 fails), and an
inequality that lets in-flight entries through (2 fail).

The last one initially passed, which meant the test was vacuous: on the happy path the
delay starts at zero, so absolute and difference are identical. It only fires on a RETRY.
`MockGov.setConfigureLie` was added to model "the call landed but the reply was lost",
which is the only way the trap can occur. With that in place the injected defect produces
31,449,600 seconds against an expected 15,724,800: exactly double.

The fourteenth control covers driver fairness: replace the rotating scan in `nextStep` with
a linear scan from index 0 and `test/fairness.sh` goes from 9/9 to 6 passed / 3 failed. The
liquid entry behind the wedged entry is credited 0 and the neuron entry behind it is never
created, which is the pre-fix behaviour.

The thirteenth control proves the mock's permission checks are not vacuous. Put the old hardcoded `[0 ... 11]` permission list back into the grant step and
rebuild: `test/e2e.sh` goes from 27/27 to **19 passed / 8 failed**, reproducing exactly the
shape the real SNS produced: one entry Done, one neuron created instead of two, the
canister still holding permissions, `settled` false. Before `MockGov.mo` learned
governance's two permission checks, that same defective module passed 27/27. That gap is
the whole reason step 5 exists.

The twelfth control is the audit one and it is the most important: remove the `unwind` from
the liquid reject handler in `Redemption.mo` and `test/repro-reject.sh` goes from 15/15 to
7 passed / 8 failed, entry 0 reports `Done`, the holder is credited 0, `reconcile` stops
balancing. That is the pre-fix behaviour, reproduced on demand.

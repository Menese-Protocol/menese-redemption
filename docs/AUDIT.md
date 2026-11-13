# Properties and the checks that prove them

Each property below holds for the holder canister as built (`src/`) at the commit that
carries this file. For each one the table names the checks that show it and the planted
faults that turn those checks red when the property is removed
(`verification/planted-faults.sh`).

Check ids: `run_tests.mo` parts are the pure-logic battery; letters followed by a number
(`B`, `D`, `F`, `G`, `H`, `Q`, `R`) are groups of the PocketIC mock suite
(`verification/pocketic/menese_redemption_mocks.rs`); ids marked *real SNS* are checks of the
run against the deployed NNS and SNS modules (`docs/VERIFY-against-a-real-sns.md`).

## Results on the module

`build/redemption.wasm`, sha256
`d3c818b5e07d9945b63d6ea57a457338a0cd5f3acd72d07be0b3ac6833174b20`.

| Run | Result |
|---|---|
| Logic battery (`test/run_tests.mo`) | 188 / 0 |
| Mock suite with failure injection (groups B, D, F, G, H, Q, R) | 93 / 0 |
| Deployed NNS and SNS modules, MENES history and a 2,000-holder world | 42 / 0, 0 SNS proposals |
| Planted faults P01 to P32 | 32 of 32 red, baseline green |
| Reproducible build (`verification/verify-build.sh`) | 6 / 6 |

## Properties

| # | Property | Checks | Planted faults |
|---|---|---|---|
| 1 | The canister has no admin method and no init argument. It binds only to an SNS whose root controls it and which NNS SNS-W lists. | mock B; real SNS `G2`, `S1` | P14 |
| 2 | Ingress `processNext` and `setNeuronDestination` are accepted only from principals in the table. | mock B | P13 |
| 3 | The snapshot fails closed: the MENES supply equals the sum of balances, no block is missing, every withdrawal after the close is resolved, each stake reads the same twice, and an aborted swap does nothing. | mock F | P08, P09, P10, P11, P12 |
| 4 | The table equals the independent builder's (`verification/table_oracle.py`): compiled-in exclusions applied, the cut inclusive of the close, the holders left out included in the hash. | mock H; real SNS `S3`, `S4` | P02, P03, P07, P22 |
| 5 | Every share is delivered as neurons: n = min(9, floor(share / U)), U = minimum stake + Split fee; nine at rungs 0 to 8, fewer at rungs 1 to n; the rounding remainder on the last part. A share below U is spread over the others by weight, repeated until none drops out. A basket of nine with a part below U moves to rungs 1 to 8 (`movedToEight`). | `run_tests.mo` parts 3 to 5 against the Python oracle; mock `H4`, `H9`; real SNS `S4`, `S5`, `N2` | P17, P19, P20, P21, P23, P24 |
| 6 | Nothing is paid out liquid: the canister's governance interface (`src/SnsGov.mo`) has no Disburse command. | mock `H7`, `Q7`; real SNS `N2` | P05 |
| 7 | Part k is split from genesis neuron k and keeps its delay (k × 182 days). A genesis neuron is handed over only by the last share owed from it. | mock H; real SNS `N1` | P01, P06 |
| 8 | Grant before strip: the destination receives every grantable permission, read live from governance, before the canister removes its own. At the end the canister holds no permission on any delivered neuron. | mock H; real SNS `N1`, `B4` | P04 |
| 9 | Every step resumes after an error, a reject or a lost reply, and across an upgrade; an unwound step returns what it booked. | mock R | P15 |
| 10 | The entry holding a genesis neuron is attempted first on every tick. | mock `Q8` | P18 |
| 11 | Only an entry's owner sets its destination; the canister itself, governance, the ledger, the management canister and the anonymous principal are refused; the destination is fixed once the basket starts; an owner who has not nominated holds up no one else. | `run_tests.mo` part 10; mock D | P16, P25 |
| 12 | Split memos are derived from a 32-byte seed the canister draws once with `raw_rand` and never returns (`Logic.splitMemo`). A part's neuron id is published once its split is sent and its memo once it is delivered. | `run_tests.mo` part 1 (vectors equal to SHA-256 computed independently in Python); mock `G1`, `G3`, `G9`; real SNS `N1` | P27, P28, P31, P32 |
| 13 | A neuron already at a part's id before its split is never taken as the part: it is reported (`getForeign()`, `stats().foreignNeurons`), left untouched and outside the books, and the part moves to its next memo. | mock `G2`, `G4` to `G8`; real SNS `P1`, `P2` | P26, P29, P30 |
| 14 | Books: delivered stake plus Split fees equal the 15,000,000 MPV to the e8s; `reconcile()` holds when each held genesis neuron's balance is at least what the books expect, and reports any surplus. | mock Q, `H7`, `Q7`; real SNS `B1` to `B3` | |
| 15 | The canister submits no SNS proposal and needs none to finish. | real SNS `B5` | |

## Defect records

| Id | Defect | Status | Record |
|---|---|---|---|
| F-1 | A permission list longer than governance's enum was refused at the grant step | Fixed: the grantable set is read live (property 8) | `docs/FINDING-grantable-permissions.md` |

## Supply chain

| Item | How it holds |
|---|---|
| Reproducible build | `build/BUILD.md`, `verification/verify-build.sh`: byte-identical across consecutive builds and across directories |
| Dependencies | `mops.lock` pins `core@2.4.0` and `sha2@0.1.9` by file hash |
| NNS and SNS modules in the real-SNS run | The mainnet modules (`docs/VERIFY-against-a-real-sns.md`) |

# Verification against deployed SNS modules

Module under test: `build/redemption.wasm`, md5 `302cdaedb94bd4cdb163421928c8e71d`, sha256
`d3c818b5e07d9945b63d6ea57a457338a0cd5f3acd72d07be0b3ac6833174b20`, 1,149,774 bytes, the
module `verification/verify-build.sh` reproduces. Run 2026-11-13.

**42 checks, 0 failures, over two MENES worlds. Every holder in the table delivered as
neurons, nothing paid out liquid, every genesis neuron handed over, zero SNS proposals.
Neurons another principal claims in the holder canister's name change nothing.**

## Method

Everything runs on PocketIC with the modules live on mainnet:

1. **The MENES ledger** module is installed at its own id and its history is **replayed**
   block by block, at each block's original index and time. The MENES sale canister's stake
   records are installed at its id.
2. **The SNS** is launched from `sns_init.yaml` by submitting a
   `CreateServiceNervousSystem` proposal to the **mainnet NNS Governance module**, adopting
   it, filling the swap and finalizing. The holder canister sits at its own id, listed among
   the dapp canisters; the SNS creates its nine genesis neurons.
3. **Nothing else is done to the holder canister.** It binds itself to the SNS, takes the
   snapshot at the swap's close, builds the table, and delivers every share, against the
   **mainnet SNS Governance module** and the **mainnet SNS ledger**. Holders nominate their
   destinations, and SNS root upgrades the canister at intervals during delivery.
4. Every neuron is read back from governance; the books are added up from governance and the
   ledger, not from the canister's own answers.

No SNS rule is reimplemented; every result is read from the deployed canisters. The NNS and
SNS modules are each verified twice when fetched: sha256 against the pinned manifest, and
against the module hash the IC itself reports. The registry module is the one exception: the
current one refuses the test subnet PocketIC creates, so the previous mainnet registry
module is used. The registry takes no part in any check.

## The worlds

| | MENES blocks | stake records | holders | in the table | baskets of nine | smaller baskets | left out | neurons |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| the MENES ledger's real history | 8,934 | 358 | 151 | 117 | 112 | 5 | 34 | 1,021 |
| synthetic (scale) | 1,998 | 776 | 2,000 | 709 | 555 | 154 | 1,291 | 5,476 |

The real history's five smaller baskets hold 1, 1, 1, 4 and 6 neurons. The holders left out
on it held 605,856,129 e8s of MENES between them (6.06 MENES); their shares went to the others.
Two rounds of the redistribution settle both worlds, and no basket of nine is moved to eight.

The table each world must produce is computed beforehand by the off-chain table builder,
independently of the canister. This document reports aggregates only.

## Results

The same checks run on both worlds; the real-history ids start with `R`, the synthetic ones
with `S` (`RL1` and `SL1` are the same check).

| check | what | real history | synthetic |
|---|---|---|---|
| L1 | every block replayed at its original index on the real ledger module | 8,934 blocks | 1,998 blocks |
| L2 | supply after the replay = initial balances less every fee | equal | equal |
| G0 | the holder canister sits at its own id | yes | yes |
| G1 | nine genesis neurons controlled by the holder canister, stakes and delays as in `sns_init.yaml` | yes | yes |
| G2 | unbound while the swap runs (NNS Root still a controller) | `Unbound` | `Unbound` |
| S1 | bound after the swap to this SNS's root, governance and ledger, with no admin | yes | yes |
| S2 | the snapshot completes | `Delivering` | `Delivering` |
| S3 | the on-chain table hash equals the off-chain builder's for the same cut | `e36e84f1…8c60b7c` | `d3c0975b…c84c979` |
| S4 | every row equals the builder's (owner, held, staked, gross, first rung, parts) | 117 rows, 0 differ | 709 rows, 0 differ |
| S5 | the list of holders left out equals the builder's; the report's counts equal the builder's | 34 of 34 | 1,291 of 1,291 |
| P1 | a swap participant disburses its delay-0 neuron and, on real governance, claims a neuron for the holder canister at every id the public memo rule (entry + 1) × 65,536 + k gives the first three baskets | 27 of 27 | 27 of 27 |
| D1 | every holder in the table nominates a destination (canister owners by their own call) | 117 | 709 |
| D2 | every share delivered and every genesis neuron handed over, through upgrades by SNS root | 499 rounds, 10 upgrades | 2,633 rounds, 53 upgrades |
| N1 | every neuron: right rung, the nominated owner holds the live grantable permissions, the holder canister none; stake and delay exact; its id the staking subaccount of (holder, its memo), the memo k for a genesis neuron and a secret memo otherwise, never the other principal's | 1,021 of 1,021 | 5,476 of 5,476 |
| N2 | no holder, destination or holder left out holds liquid MPV | 302 accounts, 0 hold MPV | 4,000 accounts, 0 hold MPV |
| B1 | delivered stake + split fees = 15,000,000 MPV | 1,500,000,000,000,000 e8s | 1,500,000,000,000,000 e8s |
| B2 | the canister's count of splits | 1,012 | 5,467 |
| B3 | `settlement()` | settled | settled |
| B4 | neurons the holder canister controls at the end, besides the other principal's | 0 | 0 |
| P2 | the other principal's neurons untouched (stake, no delay, only the holder canister as claimer), none a basket's; neurons the canister met at a part's id | 27 of 27; 0 | 27 of 27; 0 |
| B5 | SNS proposals made from genesis to the last delivery | 0 | 0 |

The splits are the neurons less nine: the last share on each genesis neuron takes the
neuron itself.

## Running it

`verification/pocketic/README.md`.

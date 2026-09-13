# F-1, neuron permission grant rejected by governance

| | |
|---|---|
| Severity | Critical |
| Status | Fixed |
| Affects | Every `#Neuron` entry |
| Introduced | `src/SnsGov.mo`, hardcoded permission list |
| Fixed in | `src/SnsGov.mo`, `src/Redemption.mo` |
| Regression cover | Negative control 13 (`build/BUILD.md`), PocketIC checks `C9b`-`C9e`, `C10b`-`C10e` |
| Present in module | `8196485adbba80dade277961d2436a32` |
| Absent from module | `7dd8a3d10c70929d6fbcc55dd1284c80` |

## Description

`SnsGov.mo` defined a fixed permission list:

```motoko
public let ALL_PERMISSIONS : [Int32] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
```

`NeuronPermissionType` defines eleven values, 0 through 10, `Unspecified`,
`ConfigureDissolveState`, `ManagePrincipals`, `SubmitProposal`, `Vote`, `Disburse`, `Split`,
`MergeMaturity`, `DisburseMaturity`, `StakeMaturity`, `ManageVotingPermission`. There is no
value 11.

SNS Governance validates the length of the submitted list against its own enum
(`rs/sns/governance/src/governance.rs:4609`) before evaluating the grantable subset
(`:4620`). A twelve-element list is therefore rejected outright:

```
AddNeuronPermissions command provided more permissions than exist in the system
```

The identical guard applies to `RemoveNeuronPermissions` (`:4646`).

## Impact

The neuron payout path has five steps: fund, claim, set dissolve delay, grant to the holder,
strip the canister's own permissions. Steps 1 to 3 complete correctly. Step 4 fails on every
attempt, permanently.

Observed end state, read from SNS Governance:

| | |
|---|---|
| Entry status | `Delayed`, does not advance |
| Neuron | Exists, correctly funded, dissolve delay exact |
| Holder permissions | None |
| Redemption canister permissions | `[0,1,2,3,4,5,6,7,8,9,10]`, sole controller |

The holder receives nothing and cannot reach the neuron. `#Granted` is the status at which
the design treats the holder as whole; no entry can reach it. The canister exposes no admin
method, so the only remedy would be an SNS DAO proposal to upgrade the canister.

A secondary defect compounds it: a governance-returned error did not register through
`noteFailure()`, so the driver's exponential backoff did not engage and the failing step was
retried at one attempt per 15-second tick indefinitely.

## Detection class

Mock-based suites verify behaviour against a model of the counterparty; a divergence between
that model and the deployed counterparty is outside what they can establish. `MockGov.mo` did
not model permission validation, so the defect was not reachable by any mock-driven check.
It is established by execution against the deployed SNS Governance module
(`verification/pocketic/`).

## Remedy

No permission list is constructed locally.

**Grant.** Reads `neuron_grantable_permissions` from the live governance canister and
submits it verbatim. The list cannot exceed the enum, and cannot contain a value the SNS
refuses to grant. If the field is absent or empty the step refuses rather than substituting
a default: granting an empty set would mark an entry `#Granted` while leaving the holder
without control.

**Strip.** Reads the neuron and removes the permissions the neuron records for this
canister. A re-read of `neuron_claimer_permissions` is not equivalent, that parameter is
DAO-modifiable between the claim and the strip, which would leave permissions held but never
removed. An empty set is treated as "already stripped" and settles the entry.

**Backoff.** A governance-returned error now registers as a failure, so the backoff engages
as designed.

**Mock.** `test/MockGov.mo` implements both governance checks, in governance's order, with
governance's error strings.

## Verification

| Suite | Result |
|---|---|
| Pure logic, incl. `PART 6` permission helpers | 115 / 0 |
| End to end, mocks | 27 / 0 |
| Reject regression | 15 / 0 |
| PocketIC, deployed SNS modules | 37 / 0 |

Negative control 13: restoring the twelve-element list takes `test/e2e.sh` from 27/27 to
19 passed / 8 failed, reproducing the failure shape observed against the deployed module.
The same defective module passed 27/27 before `MockGov.mo` implemented the permission
checks, which establishes that the control is not vacuous.

Full report: `docs/VERIFY-against-a-real-sns.md`.

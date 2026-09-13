# menese-redemption

The canister that carries existing MENES holders into the SNS.

MENES exists before the DAO does. It was distributed through a public sale and an on-chain
staking programme, and the SNS mints a *new* governance token. This canister is the route
from one to the other: a fixed list of who is owed what, a reserve funded once from
treasury, and a payout loop that runs until everybody has been paid.

**Status: not deployed.** Verified against mock counterparties, and against the deployed
SNS Governance and ICRC-1 ledger modules on PocketIC. Not independently audited.

---

## What it does

Two cohorts, distinguished by what each holder agreed to.

| Cohort | Receives |
|---|---|
| Wallet holders | Liquid tokens. They never agreed to lock anything, so nothing is locked now |
| Stakers | A neuron they control outright, carrying the remainder of the lock they chose |

A staker's dissolve delay is floored at the SNS voting minimum of 26 weeks. A staker is
never paid liquid instead.

Payment is pushed: a timer works down the list on its own. No holder has to claim, and no
holder is missed.

### The cut-off, and the table

The eligible set is fixed at a ledger block. **That block is chosen and published on the day
the SNS launches. The cut-off and the resulting table, every entry in full, are communicated
to the community at that point.** This repository fixes no date and no holder figures.

The table is a constructor argument. It is passed once at installation and no method can add,
edit or remove an entry afterwards. A wrong table cannot be corrected by any method on this
canister, only by an SNS DAO proposal to upgrade it. The pipeline that builds the table lives
outside this repository and is a separate review problem. See *Known limitations*.

## Three properties to check first

1. **There is no admin.** No method adds, edits or removes an entry, changes an amount, or
   moves the reserve anywhere but to an entry's own payout. The eligible set is fixed by the code, not by a guard on a setter.
2. **There is no mint authority.** It can only ever pay out what it was given.
3. **Status is written before the call it guards, never after.** A Motoko `await` is a
   commit point, so marking a payout complete *after* the transfer is a double-spend.

## Behaviours of the deployed modules that the design accounts for

Each is read from `dfinity/ic` rather than from documentation, and each has a test that
fails if the handling is removed.

**A claimed neuron lands at dissolve delay ZERO** (`governance.rs:4367`), and the floor to
vote is 26 weeks. So the canister claims with itself as controller, sets the delay, grants
the holder every permission, and only then removes its own. **Grant before strip**: a failure
between the two leaves a neuron the holder fully controls, which is repairable. The reverse
order can leave one nobody controls, which is not.

**`IncreaseDissolveDelay` is additive, not absolute.** A blind retry doubles the delay, so
the canister reads `get_neuron` first and sends only the difference.

**26 weeks is 182 days; `6 * 30` days is 180.** A neuron issued two days under the floor is
correctly owned and unable to vote. The constant is `15_724_800` seconds and is asserted
against the live parameter at startup; the canister refuses to run if the network's floor is
higher.

**A sub-minimum stake deletes the neuron and errors AFTER the tokens have landed**
(`governance.rs:~4392`), so the amount is checked before the transfer, never after.

**A callee that returns an error and a callee that rejects are different outcomes.** Writes
before an `await` have already committed and a trap discards only the current slice, so an
unhandled reject would leave a `#Done` mark over a transfer that never happened. Both paths
are handled: the status is unwound, and the retry is safe because `created_at_time` is fixed
on the first attempt, so the ledger deduplicates rather than paying twice. Recorded as
findings R-1 to R-5 in `docs/AUDIT-adversarial.md`.

**Permission ids are defined by governance.** The grant step reads
`neuron_grantable_permissions` from the live canister and submits it verbatim; the strip step
removes the permissions the neuron records for this canister. No list is constructed locally.
Recorded as defect F-1 in `docs/FINDING-grantable-permissions.md`.

**Internet Identity gives a different principal per origin.** The principal that staked in
the Menese app cannot control a neuron reached from the NNS dapp. So a staker nominates
where their neuron should go, via `setNeuronDestination`. Only the entry's own owner may
nominate; the immutable `owner` field still decides who is entitled. An un-nominated entry
waits indefinitely rather than falling back, and does not block the entries behind it.

## Reviewing this

Start with `docs/DESIGN.md`, then:

| | |
|---|---|
| `docs/AUDIT-adversarial.md` | adversarial audit: seven findings, with the reproduction of the critical one |
| `docs/AUDIT-final.md` | pre-release audit against the project's Motoko and upgrade rules |
| `docs/FINDING-grantable-permissions.md` | defect F-1: description, impact, root cause, remedy |
| `docs/VERIFY-against-a-real-sns.md` | the full PocketIC run, check by check |

The audit records are retained in full, including the findings that remain open.

## Layout

```
src/
  Types.mo        data model: Entry, Payout, Status, Progress
  Logic.mo        PURE decision core; no awaits, no state, no I/O
  SnsGov.mo       SNS governance interface, transcribed from governance.did
  ICRC.mo         ledger interface
  Redemption.mo   the actor
test/
  run_tests.mo    130 checks, interpreter, no replica
  MockLedger.mo   ICRC-1, with a transaction window and a failure-injection switch
  MockGov.mo      SNS governance model, including the behaviours listed above
  e2e.sh          27 checks against both mocks on a local replica
  repro-reject.sh 15 checks: the rejecting-ledger regression
  fairness.sh     9 checks: a wedged entry must not starve the entries behind it
  subaccount.py   independent reimplementation of the IC's subaccount formula
verification/
  verify-build.sh reproducible-build gate, 6 checks
  pocketic/       harness against the deployed SNS Governance and ledger modules
```

The pure-logic module holds every decision, so the arithmetic is checked exhaustively
without a replica.

## Public surface

Eleven methods. Six are read-only. None is privileged.

| | |
|---|---|
| `verifyParameters` | reads the live voting floor and refuses to run if the compiled-in floor is below it |
| `setNeuronDestination` | the owner nominates where their neuron goes |
| `process` / `processNext` | advance one entry; callable by anyone, forward only |
| `getTable` | the whole eligible set; no inclusion proof is required |
| `getProgress` / `myEntries` / `stats` / `awaitingDestination` | read-only |
| `reconcile` | INV-R1, returning both operands so the result is independently checkable |
| `settlement` | is every entry terminal and do the books balance, with the write-off count |

## Build and test

See `build/BUILD.md`. Five steps: the pure-logic battery, the module, two mock-driven
replica suites, and the PocketIC run against the deployed SNS modules. The build is
reproducible: `verification/verify-build.sh` checks that a build **from a different
directory** is byte-identical, which distinguishes reproducible from merely repeatable.

## Known limitations

- **The snapshot pipeline that produces the table has never been audited.** Every result in
  every document here is conditional on the table being right, and no method on this canister
  can correct it once installed.
- **`getTable()` publishes every holder's principal and amount on-chain**, permanently and
  linkably. This is by design, so that the eligible set is publicly verifiable. Holders
  should be informed before it happens. Open as R-7.
- **Cycle monitoring has no named owner.** The canister is DAO-governed for life rather than
  blackholed, so it must be kept topped up. Open as R-6.
- **The canister is not blackholed and is not immutable.** The table cannot be changed except
  by a public SNS upgrade vote. That is a governance guarantee, not a cryptographic one.

## Contributing

This repository was published as a single commit, by design: the product was built in a
private tree through iteration, test batteries, oracle comparison and review, and the public
repository is the clean cut of the result, without the lab work behind it. From this release
onward, work continues here in the open. Open an issue for a defect or a question, with the
file and line; open a pull request against `main` with the battery green. Contributions are
attributed to Menese Protocol.


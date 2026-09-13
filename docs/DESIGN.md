# Design

The canister that carries existing MENES holders into the SNS.

MENES exists before the DAO does. It was distributed through a public sale and an on-chain
staking programme, and the SNS mints a *new* governance token. This canister is the route
from one to the other: a fixed list of who is owed what, a reserve funded once from
treasury, and a payout loop that runs until everybody has been paid.

## 1. The eligible set

Two cohorts, and the distinction is about consent rather than convenience.

| Cohort | Receives | Why |
|---|---|---|
| Wallet holders | Liquid tokens | They never agreed to lock anything, so nothing is locked now |
| Stakers | A neuron they control outright | They continue the lock they chose |

A staker's neuron carries the remainder of that lock, floored at the SNS voting minimum of
26 weeks. A staker is **never** paid liquid instead: an entry that cannot yet be delivered
as a neuron waits indefinitely rather than falling back to something the holder did not
choose.

**The cut-off.** The table is fixed at a ledger block, chosen and published on the day the
SNS launches, not before. The cut-off and the resulting table, every entry in full, are
communicated to the community at that point. This repository fixes no date and no holder
figures.

**The table is a constructor argument.** It is passed once at installation and there is no
method that can add, edit or remove an entry afterwards. This is worth stating precisely
because it is the origin of the canister's main risk: a wrong table cannot be corrected by
any method on this canister, only by an SNS DAO proposal to upgrade it. The pipeline that
builds the table lives outside this repository and is a separate review problem.

## 2. Three properties to check first

1. **There is no admin.** Not a restricted admin, none at all. No method adds, edits or
   removes an entry, changes an amount, or moves the reserve anywhere but to an entry's own
   payout. The eligible set is fixed by the code, not by a guard on a setter.
2. **There is no mint authority.** The canister can only ever pay out what it was given.
3. **Status is written before the call it guards, never after.** A Motoko `await` is a
   commit point, so marking a payout complete *after* the transfer is a double-spend.

## 3. The status ratchet

```
Pending → Funded → Claimed → Delayed → Granted → Done
```

Forward only, enforced in one place (`Logic.canAdvance`, INV-R2). A `#Liquid` entry uses
only `Pending → Done`: one transfer, nothing to configure. A `#Neuron` entry walks the whole
chain.

`#Granted` is the safety line. At and beyond it the holder holds every permission on the
neuron, and nothing the canister does or fails to do can take it away. **Grant before
strip** is deliberate: a failure between the two leaves a neuron the holder fully controls,
which is repairable; the reverse order could leave one nobody controls, which is not.

There is one deliberate exception to forward-only, `unwind`, used when the call an advance
was guarding provably did not happen, see §6.

`#Failed` is terminal and carries its reason. It is used for an entry that is permanently
unpayable, principally a balance at or below the ledger transfer fee. Those are written off
visibly and counted, never silently skipped, and their tokens stay in the reserve.

## 4. Owner-nominated destinations

Internet Identity derives a **different principal per origin**. The principal that staked in
the Menese app therefore cannot control a neuron reached from the NNS dapp. Mailing a neuron
to the snapshot principal would hand a holder something they could never reach.

So a staker nominates the principal that should control their neuron, through
`setNeuronDestination`. The security property is unchanged: the entry's `owner` field is
immutable and decides *who is entitled*; the only principal allowed to nominate a
destination for an entry is that same owner. There is no admin, and nobody can redirect
anybody else's payout.

Waiting is not failing. An un-nominated entry stays claimable for as long as it takes, and
does not block the entries behind it.

## 5. The push

A timer works down the list on its own, so nobody has to know to claim and nobody is missed
for not reading an announcement. `process(i)` and `processNext()` are public and
unauthenticated: anyone can advance any entry, so a wedged timer can be worked around
without any new authority. Neither can move an entry backwards, and neither can send value
anywhere but to that entry's own payout.

**The scan rotates.** The driver begins each pass at a stored cursor and advances the cursor
past whatever it attempted, so every ready entry takes its turn. A scan that restarted at
index 0 each pass would stop at the first ready entry whether or not that entry could
succeed, and one permanently-failing entry would prevent every entry behind it from being
attempted at all. The cursor moves before the attempt, so an entry that traps or rejects
still yields its turn.

**Failing entries are paced, not skipped.** Each entry carries its own consecutive-failure
count. The timer applies an exponential, capped backoff per entry on top of the driver-wide
one, so a failing entry costs the table one attempt per cycle rather than every attempt.
Both counts reset to zero on the entry's first success, so recovery needs no operator. The
pacing applies only to the timer: a caller using `processNext()` by hand is never paced, and
the per-entry count never makes an entry terminal. A failing entry is not a written-off
entry.

`settlement()` names the entry with the most consecutive failures, so a table that is not
advancing says why rather than only showing entries pending.

## 6. Failure handling

The distinction that matters: a callee that **returns an error** and a callee that
**rejects** are different outcomes, and only the first was handled originally. Writes made
before an `await` have already committed, and a trap discards only the current message
slice, so a reject left a `#Done` mark standing over a transfer that never happened, in a
terminal status, with no admin. See `AUDIT-adversarial.md` R-1 to R-5.

Both paths are now handled. On a definite failure or a reject, `unwind` releases the status
mark and the accounting, so the entry stays payable. The retry is safe because
`created_at_time` is fixed on the **first** attempt and reused on every retry: an ICRC-1
ledger deduplicates on the full argument tuple, so a repeat of an attempt that secretly
landed returns `#Duplicate` rather than paying twice. Without that, a bare rollback would be
a double-spend.

If the ledger's deduplication window closes before an attempt can be confirmed, the outcome
is genuinely ambiguous. The entry is marked `#Failed` with that stated, pointing at
`reconcile()`, rather than guessed either way.

## 7. Permission ids are governance's to define

The grant step reads `neuron_grantable_permissions` from the live governance canister and
uses it verbatim; the strip step removes exactly the permissions the neuron itself says this
canister holds. Neither invents a list.

A hardcoded list that names one id more than the SNS enum defines is refused outright by
governance, so a neuron entry that had been funded, claimed and given its dissolve delay
would wedge one step short of the holder, with the canister as the neuron's sole controller.
Mock-based suites cannot establish agreement with the deployed module on this point; defect
F-1 in `FINDING-grantable-permissions.md` is the recorded instance.

## 8. The books

`reconcile()` returns `initialReserve − paidOut − feesPaid` alongside the canister's live
ledger balance, **both sides**, so the balance is checkable rather than asserted (INV-R1).

`settlement()` answers whether every entry has reached a terminal status with the books
balancing, and reports the write-off count as a number rather than folding it into the
verdict: an unpayable account is a fact the DAO should read, not a detail buried in a
boolean. It gates nothing.

## 9. Governance for life

The canister is **not** blackholed. It stays under SNS DAO control permanently.

Blackholing was considered and rejected. What it would protect is thinner than it looks:
the table is already immutable, since no method can edit it whether or not a controller
exists. It would also permanently strand the tokens of any holder who never claims, with no
route to return them to the treasury. Staying DAO-governed keeps a repair path open for
exactly the cases nobody can foresee, at the cost of requiring a public SNS upgrade vote to
use it.

The consequence to be explicit about: "the table cannot be changed" is a **governance**
guarantee, not a cryptographic one. It cannot be changed except by a public SNS upgrade
vote. It should never be described as immutable without that qualifier.

## 10. Known open items

- **R-6 and R-7** from `AUDIT-final.md` remain decisions for the maintainers, not code.
  R-7 in particular: `getTable()` publishes every holder's principal and amount on-chain,
  permanently and linkably. This is deliberate: public verifiability of the eligible set is
  the point. Holders should still be told before it happens.
- **The snapshot pipeline** that produces the table has never been audited.

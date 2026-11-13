# Design

The holder canister of the Menese Privacy SNS (MPV): it carries the people who held MENES
into the SNS.

MENES exists before the DAO does. It was distributed through a public sale and an on-chain
staking programme, and the SNS mints a *new* governance token, MPV. 15% of MPV belongs to
the MENES holders. This canister holds that 15% from the SNS's first moment, works out who
holds what at the swap's close, and hands every holder their part. No DAO proposal is
needed at any step.

## 1. Three properties to check first

1. **There is no admin and no init argument.** Everything the canister acts on is compiled
   in (the MENES ledger, the MENES sale canister, NNS SNS-W, the exclusions) or read from
   the IC after genesis (its controllers, the SNS that lists it, the swap's close, its own
   genesis neurons). The module hash fixes all of it.
2. **It cannot mint, and it holds nothing but its genesis neurons.** It can only hand them
   out by the table, as neurons, and the table is built once, by a fixed rule, and never
   changed. Its governance interface (`src/SnsGov.mo`) has no command that moves MPV out of
   a neuron, so nothing is ever paid out liquid.
3. **Every check fails closed, and status is written before the call it guards.** On any
   disagreement in the snapshot nobody is paid. A Motoko `await` is a commit point, so each
   step records what it is about to do before it does it, and every call whose reply can be
   lost has a reading that says whether it happened.

## 2. Genesis: the 15% as nine neurons

`sns_init.yaml` gives the holder canister nine developer neurons at genesis:

| neuron | memo | dissolve delay | stake |
|---|---|---|---|
| 0 | 0 | 0 days | 1,666,666 MPV |
| 1 to 7 | 1 to 7 | k × 182 days | 1,666,666 MPV each |
| 8 | 8 | 1,456 days | 1,666,672 MPV |

They add up to 15,000,000 MPV. None vests, and the token treasury holds nothing for this
share. The ladder is the swap's own: nine steps, 182 days apart, so a holder with a basket
of nine ends up with a position that unlocks in equal steps over four years and votes from
the second step on. A smaller basket takes the rungs from 182 days up.

The SNS creates the neurons with the holder canister as their controller, so the canister
holds the 15% from the first block of the SNS and nobody has to move it there.

## 3. Binding after genesis

The canister knows no SNS when it is installed. A timer looks for one:

1. `canister_info` on itself. During the swap NNS Root and SNS root share control, so it
   waits until **SNS root is the sole controller**, which happens when the swap commits.
2. That controller's `list_sns_canisters` must name this canister among the SNS's dapp
   canisters, and give the governance, ledger and swap canisters.
3. NNS SNS-W's `list_deployed_snses` must list the same root, governance and ledger.

Only then is the binding written, once. There is no method that sets it and nothing that
changes it afterwards.

The swap's lifecycle decides what comes next. **Committed**: the snapshot. **Aborted**: the
canister does nothing, ever; there is nothing to deliver.

## 4. The snapshot

Taken by the canister itself, from the chain, one step per timer tick. Each step is resumable
across upgrades.

1. **Genesis.** Reads the nine genesis neurons: each must exist, be controlled by this
   canister, carry delay k × 182 days, not vest and owe no fees, and together they must hold
   15,000,000 MPV. Reads the MPV fee and minimum stake the table is built with.
2. **Stakes, first read.** Reads the MENES sale canister's stake records 0, 1, 2, … until 64
   ids in a row are missing.
3. **Blocks.** Waits ten minutes, so that a payment for a withdrawal the sale canister had
   already recorded is in the ledger, then reads every MENES block from 0 to the tip,
   following the archives. A block timestamped at or before the close is folded into the
   balances; the first one after the close is the **cut**. A block at or before the close
   that comes after a later block halts the snapshot. So does a block that cannot be read.
4. **Supply.** The supply rebuilt from every block must equal `icrc1_total_supply`, and the
   ledger's length is read again after the supply so no block came in between.
5. **Stakes, second read.** The stake records again. If they changed, the ledger is read on
   to its new tip and the stakes once more, up to five rounds; if they keep changing, the
   snapshot halts.
6. **The table** (§5), its hash, and the published report.

**The withdrawal rule.** The sale canister keeps no record of *when* a stake was withdrawn.
Both of its withdrawal paths pay at least the stake's amount to the owner in one transfer.
So an inactive stake that existed at the close was already inactive then, unless some
transfer out of the sale canister to its owner after the cut is at least its amount. If such
a transfer exists, the stake's state at the close cannot be known and the snapshot halts.
The active stakes must also fit within what the sale canister holds at the cut.

**The exclusions** are compiled in (`src/Exclusions.mo`), per principal and per kind: a
principal can be left out for the MENES it holds, for what it has staked, or both. Every
subaccount of a principal folds into it.

**Fail closed.** Any failed check stops the canister in `#Halted` with the reason, and
nobody is paid. The report and every check line are readable (`status`, `getSnapshot`).

## 5. The table

One row per principal, in principal-text order, with its weight: MENES held at the cut plus
active stakes at the close. Every share is delivered as neurons; nothing is paid out as
liquid MPV. One **minimum neuron** U is the minimum stake plus one fee (10.0001 MPV): the
smallest part a Split can create and leave the parent able to pay its fee. Then
(`Logic.allocate`, and `split()` in the off-chain builder, the same rule):

1. **Who is in.** S_0 = every holder. Over S_i, gross = the largest-remainder share of the
   15,000,000 MPV by weight; S_{i+1} = the holders of S_i whose gross is at least U. Repeat
   until S_{i+1} = S_i. A holder left out is never added back. Leaving holders out only
   raises the others' exact shares, so a holder can fall below U in a later round only by
   one rounding unit of the largest remainder; the rounds are counted and published
   (`dropRounds`). If nobody reaches U, the snapshot halts.
2. **How many neurons.** n = min(9, floor(gross / U)) for every holder in.
3. **n from 1 to 8:** parts at rungs 1..n (delays 182 … n × 182 days), the gross in equal
   parts, the rounding remainder on the last part. Each part is at least U because
   gross ≥ n × U.
4. **n = 9:** the part at rung k is the largest-remainder share of P_k over the baskets of
   nine by weight, P_k = genesis neuron k less the smaller baskets' parts at k. Every genesis
   neuron is shared out to the e8s, so the last share on each takes the neuron itself,
   rounding units included, and nothing is left behind. If a smaller basket's parts exceed a
   genesis neuron, or no basket of nine remains to take genesis neuron 0, the snapshot halts.
5. **A basket of nine with a part below U** is moved to rungs 1..8 (its gross in eight equal
   parts, each at least U because its gross is at least 9 × U) and step 4 runs again. It only
   ever moves baskets out of the nine, so it ends. The count is published (`movedToEight`).
   This guards a case the shares of the MENES history and the scale world never reach (0
   moves in both); the mock world builds one on purpose.

The holders left out are published (`getDropped()`: owner, MENES held, staked) with their
count and total weight in the snapshot report.

The table's hash is SHA-256 over its canonical bytes (`Logic.tableBytes`). The off-chain
builder computes the same bytes from the same chain data; the two hashes are equal, which
is checked on every run (`verification/table_oracle.py`, and the PocketIC runs in
`docs/VERIFY-against-a-real-sns.md`).

## 6. Delivery

Delivery waits until governance is in Normal mode (Split is refused before the swap is
finalised) and until the fee and minimum stake are the ones the table was built
with. The grantable permissions are read live from governance on every tick (defect F-1,
`FINDING-grantable-permissions.md`).

**A basket.** For each rung k of the basket, 0 to 8 for a basket of nine, 1 to n for a
basket of n:

```
Pending ──Split part k off genesis neuron k──▶ Split ──grant to the destination──▶ Granted
   ──remove this canister's permissions──▶ next rung (Pending), or Done after the last
```

- **Split.** The child neuron keeps its parent's dissolve delay and age, so part k arrives
  with exactly k × 182 days. Its memo is secret until the split is sent (below), and
  `basketOf(i)` lists its id from then on.
- **Secret memos.** Before the first split the canister draws a 32-byte seed from the IC's
  randomness (`raw_rand`). It is kept in the canister and never returned by any method. The
  memo of entry i's part at rung k is the first eight bytes of
  SHA-256("menese-mpv-split-memo", seed, i, k, step), with the top bit set so that it is
  never a genesis memo 0 to 8 (`Logic.splitMemo`). Only the canister can compute a memo,
  so a part's neuron id is unknown outside it until the split is sent. A neuron id does not
  reveal its memo.
- **An occupied id.** A part in Pending has never had a split sent at its current memo: it
  returns to Pending only when the split provably did not happen. So a neuron found at that
  id was made by someone else. The canister reports it (`getForeign()`, `stats().foreignNeurons`),
  leaves it alone, keeps it outside the books, and moves the part to its next memo
  (step + 1). It never takes such a neuron as the part.
- **The last share on a genesis neuron takes the neuron itself.** No split; the canister
  checks its books say the neuron holds exactly that part, then hands it over. A parent is
  therefore never split below the minimum: every part is at least minimum stake + fee.
- **Grant before strip.** `AddNeuronPermissions` gives the destination every grantable
  permission; only then does `RemoveNeuronPermissions` remove the canister's own. Stopping
  between the two leaves a neuron the holder fully controls.

**The holders left out** hold nothing from this canister and cannot nominate (ingress from
a principal not in the table is refused). Their shares are in the others' baskets.

**Destinations.** Internet Identity gives a different principal per origin, so the principal
a holder used in the Menese app cannot control a neuron reached from the NNS dapp. Every
holder receiving a basket nominates where it goes, with `setNeuronDestination`. Only the
entry's owner can nominate. The destination can change until the basket starts and is then
fixed, so all the basket's neurons go to one principal. Destinations nobody could use are refused:
the anonymous principal, governance, the ledger, the management canister, and this canister
itself (the strip would leave such a neuron controlled by nobody). A basket waiting for its
destination waits for as long as it takes and holds up nobody else.

## 7. Lost replies, rejects, upgrades

**One operation per genesis neuron at a time.** While an entry's Split of genesis neuron k
is sent and not confirmed (`parentBusy[k]`), nothing else touches neuron k. So its
balance is an exact reading of whether the operation happened.

- **A Split** whose reply is lost or rejected is confirmed by the child neuron: if it exists
  and holds its part, the split happened. If it does not exist, the step returns to `Pending`
  on the same neuron and the books release the part.
- **A definite error** from governance returns the step to `Pending` on the same neuron.
- **Grant and strip** read the neuron back first, so a repeat after a lost reply is a no-op.

The statuses only move forward (`Logic.canMove`); the one way back, `unwind`, is used only
when the step provably did not happen, and it returns to `Pending` on the same neuron.

**Scheduling.** A timer drives delivery every 15 seconds, a few steps per tick. The entry
holding a genesis neuron (`parentBusy`) is attempted first, before anything else, so a retry
never depends on where the scan stands. The other entries are taken from a rotating cursor,
and an entry waiting for a busy genesis neuron is passed over without using a step. Failing
entries are paced per entry, not skipped. `processNext()` drives a step by hand if the timer
is ever wedged.

**Upgrades.** The module uses enhanced orthogonal persistence; an upgrade by SNS root with
`wasm_memory_persistence = keep` resumes exactly where the canister stopped, in the
snapshot or in delivery. The tests upgrade it at every step.

## 8. The books

`reconcile()` reads every genesis neuron still held and compares its balance with what the
table still owes from it: `holds` if each has at least that. Anything above is reported as
`surplus` (a donation), never treated as a mismatch. `poolAccounted` ties the statuses to the
books: what the entries' statuses say has left the genesis neurons, plus what the neurons
still held owe, is the whole 15,000,000 MPV, to the e8s.

`settlement()` says whether every share is delivered, every genesis neuron handed over and
the books hold, with the counts.

## 9. Who may call what

| | |
|---|---|
| `setNeuronDestination` | the owner of a basket entry; ingress only from principals in the table |
| `processNext` | anyone in the table, as ingress; any canister |
| `reconcile`, `settlement` | canisters only (they call other canisters for the caller) |
| `getTable`, `getEntries`, `getDropped`, `getSnapshot`, `getBinding`, `status`, `getProgress`, `myEntries`, `basketOf`, `getForeign`, `stats` | anyone; read-only |

`inspect` refuses the ingress messages above before they run. Nothing on the list can move
value anywhere but to an entry's own destination.

## 10. Governance for life

The canister is not blackholed. After the swap SNS root is its sole controller, so the SNS
DAO can upgrade it by proposal, and no one else can. The table is fixed by the code; a change
would need a public SNS vote on a new module.

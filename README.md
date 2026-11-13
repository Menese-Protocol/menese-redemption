# menese-redemption

The holder canister of the Menese Privacy SNS (MPV): it carries the people who held MENES
into the SNS.

15% of MPV belongs to the MENES holders. The SNS creates it at genesis as nine neurons owned
by this canister. When the swap commits, the canister takes the holder snapshot itself from
the MENES ledger and the MENES sale canister, publishes the table and its hash, and hands
every holder their part. No DAO proposal is needed at any step.

**Status: not deployed.** Verified against failure-injecting mocks, and against the deployed
NNS and SNS modules on PocketIC with the real MENES ledger history replayed.

---

## What every holder receives

Neurons only, the same kind the swap gives its own participants. Each holder's share is
counted in **minimum neurons**: the SNS minimum stake plus one fee, 10.0001 MPV.

| Share | Delivered as |
|---|---|
| nine minimum neurons or more | **a basket of nine neurons**, dissolve delays 0, 182, 364, … 1,456 days, one split off each genesis neuron |
| n minimum neurons, n from 1 to 8 | **n neurons** with delays 182, 364, … n × 182 days, the share in equal parts (the rounding remainder on the last) |
| less than one minimum neuron | spread over the other holders by their weight |

Each part keeps its genesis neuron's delay, so a holder's position unlocks in equal steps
and votes from the 182-day step on. A share smaller than one minimum neuron cannot be a
neuron, so it goes to the others: the shares are worked out again over the holders who
remain, and again, until every remaining share is at least one minimum neuron. The holders
left out are published with the table, and the table's hash covers them.

Holders who held MENES directly and holders who had it staked are paid the same way.

## How it works

1. **Genesis.** `sns_init.yaml` gives this canister nine neurons, 1,666,666 MPV each (the
   last 1,666,672), delays k × 182 days, no vesting.
2. **Binding.** Once SNS root is its sole controller and NNS SNS-W lists that SNS, the
   canister binds to it. No admin, no key, no init argument.
3. **Snapshot.** At the swap's close it reads every MENES block to the tip, the sale
   canister's stake records twice, and checks the supply against the ledger. It applies the
   compiled-in exclusions and builds the table by a fixed rule. Any failed check stops it,
   and nobody is paid. If the swap is aborted, it does nothing.
4. **Delivery.** Each part is split off its genesis neuron, granted to the holder's chosen
   principal, and then the canister removes itself. The last share on each genesis neuron
   takes the neuron itself, rounding units included, so the canister ends holding nothing.
   Nothing is ever paid out as liquid MPV.

`docs/DESIGN.md` has the whole design.

## Three properties to check first

1. **There is no admin and no init argument.** The module hash fixes everything the
   canister acts on.
2. **It cannot mint or pay out.** It holds only its nine genesis neurons and hands them out
   by the table, as neurons. Its governance interface has no command that moves MPV out of
   a neuron.
3. **Status is written before the call it guards.** Every call whose reply can be lost has a
   reading that says whether it happened, so nothing is delivered twice or lost.

## For holders

- `myEntries()` shows your share and its progress.
- `setNeuronDestination(principal)` sets where your basket goes, for example the principal
  you use in the NNS dapp. You can change it until your basket starts.
- `basketOf(i)` lists your neurons: stakes, delays, and which are delivered. Each neuron's
  id appears once it is split off for you.
- `getTable()`, `getDropped()`, `getSnapshot()` and `stats()` show everyone's shares, the
  holders left out, the snapshot's checks and its hash, and the totals.

## Reviewing this

| | |
|---|---|
| `docs/DESIGN.md` | the design |
| `docs/AUDIT.md` | each property, the checks that prove it, and the planted faults that break them |
| `docs/FINDING-grantable-permissions.md` | defect F-1 |
| `docs/VERIFY-against-a-real-sns.md` | the PocketIC run against the deployed modules, check by check |

## Layout

```
src/
  Redemption.mo   the actor: binding, snapshot, table, delivery, books
  Logic.mo        pure decisions: the table rule, the status ratchet, the books; no awaits
  Types.mo        data model
  Ifaces.mo       MENES ledger, sale canister, SNS root, swap, SNS-W, MPV ledger interfaces
  SnsGov.mo       SNS governance interface, transcribed from governance.did
  Exclusions.mo   who is left out of the snapshot, and for what
test/
  run_tests.mo    the pure-logic battery, interpreter, no replica
  Vectors.mo      table vectors from the independent Python oracle
  MockSns.mo, MockMenesLedger.mo, MockSale.mo, Proxy.mo   failure-injecting mocks
verification/
  verify-build.sh     reproducible-build gate
  planted-faults.sh   one named defect per property; each must turn its test red
  table_oracle.py     the table rule stated independently in Python
  mock_world.py, real_world.py   MENES worlds for the PocketIC runs
  pocketic/           the mock suite and the run against the deployed modules
```

## Build and test

See `build/BUILD.md`. The build is reproducible: `verification/verify-build.sh` checks that a
build from a different directory is byte-identical.

## Contributing

Open an issue for a defect or a question, with the file and line; open a pull request
against `main` with the tests green. Contributions are attributed to Menese Protocol.

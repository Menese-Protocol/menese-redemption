#!/usr/bin/env bash
# e2e.sh, drive the redemption canister against mock ledger + mock governance.
#
# Exercises both payout kinds, the five-step neuron path, the unpayable-dust path, the
# idempotency of a repeated call, and recovery from an injected ledger failure.
# Every assertion is a value comparison, not a "did it not crash".
set -u
export DFX_WARNING=-mainnet_plaintext_identity
cd "$(dirname "$0")/.."
NET=local
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); printf "  ok   %-52s %s\n" "$1" "$2"
      else fail=$((fail+1)); printf "  FAIL %-52s got=%s want=%s\n" "$1" "$2" "$3"; fi; }
call(){ dfx canister call "$@" --network $NET 2>&1 | grep -v WARNING; }

FEE=10000
MIN=1000000000          # 10 MENES
FLOOR=15724800          # 26 weeks
D18=47260800            # 547 days

# holders (any valid principals; the mock does not care who they are)
HA=3gs3h-yg6vu-aaaaa-aaaaa-cai   # liquid, payable
HB=3bt5t-v66vu-aaaaa-aaaaq-cai   # liquid, DUST -> unpayable
# Both neuron entries are owned by the harness identity, so it can nominate as the owner.
HC=$(dfx identity get-principal 2>/dev/null)   # neuron at the floor, owned by the harness
HD="$HC"                                       # neuron at 18 months, same owner
# Where the neurons should actually go: a DIFFERENT principal, standing in for the holder's
# NNS-dapp identity. If the canister ignores the nomination this comes out wrong.
DEST=3iqwp-dw6vu-aaaaa-aaaba-cai

echo "== deploy =="
dfx deploy mock_ledger --network $NET --argument "($FEE : nat)" -y >/dev/null 2>&1
LED=$(dfx canister id mock_ledger --network $NET 2>/dev/null)
dfx deploy mock_gov --network $NET --argument "(principal \"$LED\", $MIN : nat, $FLOOR : nat64)" -y >/dev/null 2>&1
GOV=$(dfx canister id mock_gov --network $NET 2>/dev/null)

AMT_A=500000000          # 5 MENES liquid
AMT_B=5000               # below the fee -> unpayable
AMT_C=2000000000         # 20 MENES neuron
AMT_D=1000000000         # 10 MENES neuron
RESERVE=$((AMT_A+AMT_B+AMT_C+AMT_D+4*FEE))

ENTRIES="vec {
 record { owner=principal \"$HA\"; amount=$AMT_A:nat; payout=variant{Liquid}; source=variant{Wallet} };
 record { owner=principal \"$HB\"; amount=$AMT_B:nat; payout=variant{Liquid}; source=variant{Wallet} };
 record { owner=principal \"$HC\"; amount=$AMT_C:nat; payout=variant{Neuron=record{delaySeconds=$FLOOR:nat64}}; source=variant{Stake=1:nat} };
 record { owner=principal \"$HD\"; amount=$AMT_D:nat; payout=variant{Neuron=record{delaySeconds=$D18:nat64}}; source=variant{Stake=2:nat} };
}"
dfx deploy redemption --network $NET --argument "(record {
  ledger=principal \"$LED\"; governance=principal \"$GOV\"; entries=$ENTRIES;
  initialReserve=$RESERVE:nat; fee=$FEE:nat })" -y >/dev/null 2>&1
RED=$(dfx canister id redemption --network $NET 2>/dev/null)
echo "  ledger=$LED  gov=$GOV  redemption=$RED"

echo "== fund the reserve =="
call mock_ledger mint "(record{owner=principal \"$RED\"}, $RESERVE : nat)" >/dev/null

echo "== refuses to run before the floor is verified =="
r=$(call redemption process "(0 : nat)")
case "$r" in *"verifyParameters"*) ok "refuses before verifyParameters" yes yes ;; *) ok "refuses before verifyParameters" "$r" yes ;; esac

# Settlement must be false here, before anything has run. Asserting it at both ends is what
# stops the final `true` from being a query that simply always says yes.
sb0=$(call redemption settlement "()")
st0=$(echo "$sb0" | grep -oE 'settled = (true|false)' | awk '{print $3}')
ok "not settled before anything has been processed" "$st0" "false"

echo "== verify the live voting floor =="
r=$(call redemption verifyParameters "()")
case "$r" in *ok*) ok "floor check passes" yes yes ;; *) ok "floor check passes" "$r" yes ;; esac

echo "== inject a ledger failure and confirm it recovers without paying twice =="
call mock_ledger setFailNext "(1 : nat)" >/dev/null
r=$(call redemption processNext "()")
case "$r" in *err*) ok "a failed transfer is reported, not swallowed" yes yes ;;
                *) ok "a failed transfer is reported, not swallowed" "$r" yes ;; esac
b0=$(call mock_ledger icrc1_balance_of "(record{owner=principal \"$HA\"})" | grep -oE '[0-9_]+' | tr -d '_')
ok "nothing was paid out on the failed attempt" "$b0" "0"

echo "== a staker's neuron WAITS until its owner nominates a destination =="
aw=$(call redemption awaitingDestination "()" | grep -oE '[0-9_]+' | tr -d '_')
ok "both neuron entries are waiting on a destination" "$aw" "2"
for i in $(seq 1 6); do call redemption processNext "()" >/dev/null; done
nc0=$(call mock_gov neuronCount "()" | grep -oE '[0-9_]+' | tr -d '_')
ok "no neuron is created before a destination is nominated" "$nc0" "0"
ok "a waiting entry does NOT block the liquid ones behind it" \
   "$(call mock_ledger icrc1_balance_of "(record{owner=principal \"$HA\"})" | grep -oE '[0-9_]+' | tr -d '_')" "$AMT_A"

echo "== only the entry's own owner may nominate =="
r=$(call redemption setNeuronDestination "(principal \"$DEST\")")
n=$(echo "$r" | grep -oE '[0-9_]+' | tr -d '_')
ok "the owner nominates both of their neuron entries" "$n" "2"
aw2=$(call redemption awaitingDestination "()" | grep -oE '[0-9_]+' | tr -d '_')
ok "nothing is waiting once nominated" "$aw2" "0"

echo "== force a RETRY of the dissolve-delay step =="
# The delay is applied but the reply is lost, so the canister retries Configure. If it
# sends the absolute delay rather than the difference, the delay DOUBLES.
call mock_gov setConfigureLie "(1 : nat)" >/dev/null

echo "== drive the table to completion =="
for i in $(seq 1 40); do call redemption processNext "()" >/dev/null; done

echo "== assertions =="
b=$(call mock_ledger icrc1_balance_of "(record{owner=principal \"$HA\"})" | grep -oE '[0-9_]+' | tr -d '_')
ok "liquid holder received the full amount" "$b" "$AMT_A"

st=$(call redemption stats "()")
done_n=$(echo "$st" | grep -oE 'done = [0-9_]+' | grep -oE '[0-9_]+' | tr -d '_')
failed_n=$(echo "$st" | grep -oE 'failed = [0-9_]+' | grep -oE '[0-9_]+' | tr -d '_')
ok "three entries reached Done" "$done_n" "3"
ok "the dust entry is marked failed, not silently skipped" "$failed_n" "1"

nc=$(call mock_gov neuronCount "()" | grep -oE '[0-9_]+' | tr -d '_')
ok "two neurons created" "$nc" "2"

echo "== reconciliation (INV-R1) =="
rec=$(call redemption reconcile "()")
holds=$(echo "$rec" | grep -oE 'holds = (true|false)' | awk '{print $3}')
ok "INV-R1 holds" "$holds" "true"

echo "== idempotency: process an already-finished entry =="
before=$(call mock_ledger icrc1_balance_of "(record{owner=principal \"$HA\"})" | grep -oE '[0-9_]+' | tr -d '_')
call redemption process "(0 : nat)" >/dev/null
after=$(call mock_ledger icrc1_balance_of "(record{owner=principal \"$HA\"})" | grep -oE '[0-9_]+' | tr -d '_')
ok "a repeated call does not pay twice" "$after" "$before"

echo "== the neurons themselves =="
SUBS=$(python3 test/subaccount.py "$RED" 2 3)
while IFS= read -r line; do
  memo="${line%%|*}"; sub="${line#*|}"
  n=$(call mock_gov inspect "($sub : blob)")
  d=$(echo "$n" | grep -oE 'delay = [0-9_]+' | grep -oE '[0-9_]+' | tr -d '_')
  np=$(echo "$n" | grep -c 'principal')
  if [ "$memo" = "2" ]; then
    ok "neuron 2 delay is EXACT, not doubled by a retry" "$d" "$FLOOR"
    case "$n" in *"$DEST"*) ok "neuron 2 went to the NOMINATED principal" yes yes ;; *) ok "neuron 2 went to the NOMINATED principal" no yes ;; esac
    case "$n" in *"$HC"*) ok "neuron 2 did NOT go to the snapshot principal" no yes ;; *) ok "neuron 2 did NOT go to the snapshot principal" yes yes ;; esac
  else
    ok "neuron 3 delay is EXACT (18 months)" "$d" "$D18"
    case "$n" in *"$DEST"*) ok "neuron 3 went to the NOMINATED principal" yes yes ;; *) ok "neuron 3 went to the NOMINATED principal" no yes ;; esac
  fi
  case "$n" in *"$RED"*) ok "canister removed itself from neuron $memo" no yes ;;
                     *) ok "canister removed itself from neuron $memo" yes yes ;; esac
  ok "neuron $memo has exactly one controller" "$np" "1"
done <<< "$SUBS"

echo "== settlement =="
# Every entry is now terminal: three paid, one written off as below the fee. Under the old
# blackhole rule a single #Failed entry made this false forever, so it could never be
# observed true on any table with dust in it -- which is every real table.
sb=$(call redemption settlement "()")
st=$(echo "$sb" | grep -oE 'settled = (true|false)' | awk '{print $3}')
wo=$(echo "$sb" | grep -oE 'writtenOff = [0-9_]+' | awk '{print $3}' | tr -d _)
ok "settled once every entry is terminal" "$st" "true"
ok "reports the write-off as a count, not a refusal" "$wo" "1"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1

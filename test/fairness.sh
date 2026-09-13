#!/usr/bin/env bash
# fairness.sh: one permanently-failing entry must not stop the entries behind it.
#
# The driver used to scan from index 0 on every pass and stop at the first entry that was
# ready, whether or not that entry could succeed. An entry that always failed therefore
# consumed every pass and nothing behind it was ever attempted.
#
# This drives a table whose SECOND entry can never complete: MockGov refuses every
# AddNeuronPermissions on that entry's neuron, which is the shape of a real governance-side
# refusal. The neuron is named by its staking subaccount, derived independently by
# test/subaccount.py, so exactly one entry is wedged. The assertions are that entry 1 stays
# stuck, and that entries 0, 2 and 3 all finish anyway.
set -u
export DFX_WARNING=-mainnet_plaintext_identity
cd "$(dirname "$0")/.."
NET=local
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); printf "  ok   %-56s %s\n" "$1" "$2"
      else fail=$((fail+1)); printf "  FAIL %-56s got=%s want=%s\n" "$1" "$2" "$3"; fi; }
call(){ dfx canister call "$@" --network $NET 2>&1 | grep -v WARNING; }

FEE=10000
MIN=1000000000
FLOOR=15724800

SELF=$(dfx identity get-principal 2>/dev/null)
HA=3gs3h-yg6vu-aaaaa-aaaaa-cai      # 0: liquid, ahead of the wedge
HC=3iqwp-dw6vu-aaaaa-aaaba-cai      # 2: liquid, BEHIND the wedge
DEST=3prq3-oo6vu-aaaaa-aaabq-cai    # where both neuron entries are nominated to go

AMT_A=500000000
AMT_B=2000000000
AMT_C=300000000
AMT_D=1000000000
RESERVE=$((AMT_A+AMT_B+AMT_C+AMT_D+4*FEE))

echo "== deploy =="
dfx deploy mock_ledger --network $NET --argument "($FEE : nat)" -y >/dev/null 2>&1
LED=$(dfx canister id mock_ledger --network $NET 2>/dev/null)
dfx deploy mock_gov --network $NET --argument "(principal \"$LED\", $MIN : nat, $FLOOR : nat64)" -y >/dev/null 2>&1
GOV=$(dfx canister id mock_gov --network $NET 2>/dev/null)

# Entries 1 and 3 are owned by the harness identity so it can nominate for both.
ENTRIES="vec {
 record { owner=principal \"$HA\";   amount=$AMT_A:nat; payout=variant{Liquid}; source=variant{Wallet} };
 record { owner=principal \"$SELF\"; amount=$AMT_B:nat; payout=variant{Neuron=record{delaySeconds=$FLOOR:nat64}}; source=variant{Stake=1:nat} };
 record { owner=principal \"$HC\";   amount=$AMT_C:nat; payout=variant{Liquid}; source=variant{Wallet} };
 record { owner=principal \"$SELF\"; amount=$AMT_D:nat; payout=variant{Neuron=record{delaySeconds=$FLOOR:nat64}}; source=variant{Stake=2:nat} };
}"
dfx deploy redemption --network $NET --argument "(record {
  ledger=principal \"$LED\"; governance=principal \"$GOV\"; entries=$ENTRIES;
  initialReserve=$RESERVE:nat; fee=$FEE:nat })" -y >/dev/null 2>&1
RED=$(dfx canister id redemption --network $NET 2>/dev/null)
call mock_ledger mint "(record{owner=principal \"$RED\"}, $RESERVE : nat)" >/dev/null
call redemption verifyParameters "()" >/dev/null

echo "== nominate, then wedge entry 1 permanently =="
call redemption setNeuronDestination "(principal \"$DEST\")" >/dev/null
# Entry 1's neuron subaccount, derived from (redemption canister, memo 1) by the independent
# reimplementation of the IC's formula rather than by the canister under test.
SUB1=$(python3 test/subaccount.py "$RED" 1 | cut -d'|' -f2)
call mock_gov setGrantRefusalForSubaccount "(opt $SUB1)" >/dev/null

echo "== drive the table with processNext only =="
i=0; while [ $i -lt 40 ]; do call redemption processNext "()" >/dev/null; i=$((i+1)); done

echo "== the wedged entry stays wedged =="
s1=$(call redemption getProgress "()" | tr ';' '\n' | grep -c "Delayed")
ok "entry 1 never reaches a terminal status" "$( [ "$s1" -ge 1 ] && echo yes || echo no )" yes

echo "== every other entry finishes anyway =="
done_n=$(call redemption stats "()" | grep -oE "done = [0-9_]+" | grep -oE "[0-9_]+" | tr -d _)
ok "three of four entries reach Done" "$done_n" 3

bal_a=$(call mock_ledger icrc1_balance_of "(record{owner=principal \"$HA\"})" | grep -oE "[0-9_]+" | tr -d _ | head -1)
ok "entry 0, ahead of the wedge, was paid" "$bal_a" "$AMT_A"
bal_c=$(call mock_ledger icrc1_balance_of "(record{owner=principal \"$HC\"})" | grep -oE "[0-9_]+" | tr -d _ | head -1)
ok "entry 2, BEHIND the wedge, was paid" "$bal_c" "$AMT_C"

# Entry 3 is a neuron behind the wedge: it has to walk five steps, every one of which the
# old driver would have denied it.
n=$(call mock_gov neuronCount "()" | grep -oE "[0-9_]+" | tr -d _ | head -1)
ok "entry 3, a neuron behind the wedge, was created" "$n" 2

echo "== the stall is reported, not silent =="
reason=$(call redemption settlement "()")
case "$reason" in *"entry 1 has failed"*) ok "settlement names the stalled entry" yes yes ;;
                  *) ok "settlement names the stalled entry" "$reason" yes ;; esac
case "$reason" in *"settled = false"*) ok "the run is correctly not settled" yes yes ;;
                  *) ok "the run is correctly not settled" "$reason" yes ;; esac

echo "== the wedge clears the moment governance stops refusing =="
call mock_gov setGrantRefusalForSubaccount "(null : opt blob)" >/dev/null
i=0; while [ $i -lt 10 ]; do call redemption processNext "()" >/dev/null; i=$((i+1)); done
done_n=$(call redemption stats "()" | grep -oE "done = [0-9_]+" | grep -oE "[0-9_]+" | tr -d _)
ok "all four entries finish once the refusal is lifted" "$done_n" 4
set_r=$(call redemption settlement "()")
case "$set_r" in *"settled = true"*) ok "the run settles" yes yes ;;
                 *) ok "the run settles" "$set_r" yes ;; esac

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1

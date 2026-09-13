#!/usr/bin/env bash
# repro-reject.sh: the regression test for audit findings R-1, R-2 and R-3.
#
# A ledger that RETURNS an error and one that REJECTS are different outcomes. Before the
# fix only the first was handled: a reject trapped the message, everything committed before
# the await survived, and the driver marked entry after entry #Done while paying nobody.
# This drove that, three entries destroyed in three ticks.
#
# The same script now asserts the opposite, against the same trapping ledger:
#
#   R-3  the #Done mark and the accounting are unwound, so the entry stays payable
#   R-2  busy[i] is released, so the entry is admitted again
#   R-1  once the ledger recovers every holder is credited EXACTLY ONCE
#
# The last point is what the ICRC-1 dedup modelling in MockLedger is for: a rollback is only
# safe if a retry of an attempt that secretly landed comes back #Duplicate.
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

HA=3gs3h-yg6vu-aaaaa-aaaaa-cai
HB=3iqwp-dw6vu-aaaaa-aaaba-cai
HC=3bt5t-v66vu-aaaaa-aaaaq-cai

echo "== deploy =="
dfx deploy mock_ledger --network $NET --argument "($FEE : nat)" -y >/dev/null 2>&1
LED=$(dfx canister id mock_ledger --network $NET 2>/dev/null)
dfx deploy mock_gov --network $NET --argument "(principal \"$LED\", $MIN : nat, $FLOOR : nat64)" -y >/dev/null 2>&1
GOV=$(dfx canister id mock_gov --network $NET 2>/dev/null)

AMT=500000000
RESERVE=$((3*AMT+3*FEE))
ENTRIES="vec {
 record { owner=principal \"$HA\"; amount=$AMT:nat; payout=variant{Liquid}; source=variant{Wallet} };
 record { owner=principal \"$HB\"; amount=$AMT:nat; payout=variant{Liquid}; source=variant{Wallet} };
 record { owner=principal \"$HC\"; amount=$AMT:nat; payout=variant{Liquid}; source=variant{Wallet} };
}"
dfx deploy redemption --network $NET --argument "(record {
  ledger=principal \"$LED\"; governance=principal \"$GOV\"; entries=$ENTRIES;
  initialReserve=$RESERVE:nat; fee=$FEE:nat })" -y >/dev/null 2>&1
RED=$(dfx canister id redemption --network $NET 2>/dev/null)
call mock_ledger mint "(record{owner=principal \"$RED\"}, $RESERVE : nat)" >/dev/null
call redemption verifyParameters "()" >/dev/null

echo "== arm the ledger to REJECT (trap) on the next transfer =="
call mock_ledger setTrapNext "(1 : nat)" >/dev/null

echo "== drive entry 0 into the reject =="
r=$(call redemption process "(0 : nat)")
case "$r" in *"rejected"*|*"trap"*) ok "the reject is caught and reported, not fatal" yes yes ;;
                                 *) ok "the reject is caught and reported, not fatal" "$r" yes ;; esac

echo "== R-3 fixed: the mark is unwound, not left standing =="
p=$(call redemption getProgress "()" | tr -d ' \n')
st0=$(echo "$p" | grep -oE 'status=variant\{[A-Za-z]+' | head -1 | sed 's/.*{//')
ok "entry 0 is back at Pending, not falsely Done" "$st0" "Pending"
s=$(call redemption stats "()")
done_n=$(echo "$s" | grep -oE 'done = [0-9_]+' | awk '{print $3}' | tr -d _)
paid=$(echo "$s" | grep -oE 'paidOut = [0-9_]+' | awk '{print $3}' | tr -d _)
ok "nothing is counted as done" "$done_n" "0"
ok "the accounting was rolled back too" "$paid" "0"

echo "== R-2 fixed: the busy latch was released =="
r2=$(call redemption process "(0 : nat)")
case "$r2" in *"busy"*) ok "entry 0 is admitted again, not stuck busy" "$r2" "not-busy" ;;
                     *) ok "entry 0 is admitted again, not stuck busy" yes yes ;; esac

echo "== R-1 fixed: the ledger recovered, so everyone gets paid exactly once =="
# Disarm. A trap rolls back the mock's own counter, so setTrapNext(1) keeps trapping until
# it is cleared -- which happens to model a persistently-down ledger, and is exactly why the
# unfixed canister destroyed the whole table rather than one entry.
call mock_ledger setTrapNext "(0 : nat)" >/dev/null
call redemption processNext "()" >/dev/null 2>&1
call redemption processNext "()" >/dev/null 2>&1
call redemption processNext "()" >/dev/null 2>&1
call redemption processNext "()" >/dev/null 2>&1
p2=$(call redemption getProgress "()" | tr -d ' \n')
dn=$(echo "$p2" | grep -oE 'status=variant\{Done' | wc -l)
ok "all three entries reach Done" "$dn" "3"
for h in "$HA" "$HB" "$HC"; do
  b=$(call mock_ledger icrc1_balance_of "(record{owner=principal \"$h\"})" | grep -oE '[0-9_]+' | head -1 | tr -d _)
  ok "holder $h credited the full amount" "${b:-0}" "$AMT"
done
tc=$(call mock_ledger transferCount "()" | grep -oE '[0-9_]+' | head -1 | tr -d _)
ok "exactly three transfers moved value: no double payment" "$tc" "3"

echo "== INV-R1 balances again =="
rec=$(call redemption reconcile "()")
holds=$(echo "$rec" | grep -oE 'holds = (true|false)' | awk '{print $3}')
ok "reconcile holds after the recovery" "$holds" "true"

echo "== the dedup that makes the retry safe is real =="
# Re-driving a finished entry must not pay again. Terminal status stops it first.
call redemption process "(0 : nat)" >/dev/null 2>&1
tc2=$(call mock_ledger transferCount "()" | grep -oE '[0-9_]+' | head -1 | tr -d _)
ok "re-driving a paid entry moves no further value" "$tc2" "3"

# Terminal status is the FIRST line of defence. The rollback in R-1's fix depends on a
# SECOND: that a retry of a transfer which secretly landed comes back #Duplicate rather than
# paying again. Assert that directly against the ledger, because the whole safety argument
# for unwinding a mark rests on it, and an unexercised mock feature proves nothing.
# Mint to the identity that will make the call, not to the canister: `from` is the caller.
ME=$(dfx identity get-principal 2>/dev/null)
call mock_ledger mint "(record{owner=principal \"$ME\"}, 100000000 : nat)" >/dev/null
ARGS="(record{ from_subaccount=null; to=record{owner=principal \"$HA\"}; amount=1000:nat; fee=opt($FEE:nat); memo=null; created_at_time=opt(777777:nat64) })"
t1=$(call mock_ledger icrc1_transfer "$ARGS")
t2=$(call mock_ledger icrc1_transfer "$ARGS")
case "$t1" in *Ok*) ok "an identical first transfer succeeds" yes yes ;; *) ok "an identical first transfer succeeds" "$t1" yes ;; esac
case "$t2" in *Duplicate*) ok "the identical repeat is refused as #Duplicate" yes yes ;;
                        *) ok "the identical repeat is refused as #Duplicate" "$t2" yes ;; esac

echo "== settlement =="
sb=$(call redemption settlement "()")
st=$(echo "$sb" | grep -oE 'settled = (true|false)' | awk '{print $3}')
ok "the run reports settled" "$st" "true"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1

#!/usr/bin/env python3
"""Print the SNS staking subaccount for (controller, memo) as a Candid blob literal.
Independent reimplementation of rs/nervous_system/common/src/ledger.rs, so the harness
checks the canister against the IC's formula rather than against the canister's own copy."""
import base64, hashlib, sys
def dec(t):
    s = t.replace("-", "").upper(); s += "=" * ((-len(s)) % 8)
    return base64.b32decode(s)[4:]
ctrl = dec(sys.argv[1])
for memo in [int(a) for a in sys.argv[2:]]:
    h = hashlib.sha256(bytes([12]) + b"neuron-stake" + ctrl + memo.to_bytes(8, "big")).digest()
    print(str(memo) + "|vec {" + "; ".join(str(b) for b in h) + "}")

#!/usr/bin/env python3
"""Temporary: confirm the base58 alphabet and WIF decoder are not the bug."""
import secrets
import sys

sys.path.insert(0, "scripts")
from gen_founder_key import (B58, NETWORKS, to_wif, wif_to_privkey)  # noqa: E402

print("=== base58 alphabet as the code actually has it ===")
print(f"  length : {len(B58)}  (must be 58)")
print(f"  {B58}")
print()

for ch in "jJiIlL0Oo":
    idx = B58.find(ch)
    verdict = f"present at index {idx}" if idx >= 0 else "ABSENT (excluded by design)"
    print(f"  {ch!r:>5} -> {verdict}")

print()
print("=== can the verifier decode a WIF that contains 'j'? ===")
found = None
for _ in range(2000):
    k = secrets.randbits(256)
    w = to_wif(k, NETWORKS["testnet"]["secret"], True)
    if "j" in w:
        found = (k, w)
        break

if not found:
    print("  no WIF containing 'j' generated in 2000 tries -- unexpected")
    sys.exit(1)

k, w = found
print(f"  generated a WIF containing {w.count('j')} x 'j'")
try:
    priv, ver, comp = wif_to_privkey(w)
    print(f"  decode: {'OK' if priv == k else 'WRONG KEY'}")
except ValueError as exc:
    print(f"  decode FAILED: {exc}   <-- bug in our code")
    sys.exit(1)

print()
print("  Conclusion: 'j' is valid base58 and our decoder accepts it.")
print("  A rejection naming 'j' therefore means the character TYPED was not")
print("  an ASCII 'j' -- most likely a lookalike from a non-Latin keyboard")
print("  layout, or a different letter read off the paper.")

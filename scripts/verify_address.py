#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""
verify_address.py -- check a WAM address before you build anything on it.

    python3 scripts/verify_address.py "$(cat /media/usb/addr.txt)"

Run this on the online machine the moment the address arrives from the offline
one, and before it goes anywhere near chainparams.cpp.

Why it exists: the base58 checksum is the only thing standing between a
one-character slip and a genesis block that pays 2,000,000 WAM to a script
nobody holds the key to. During rehearsal, two consecutive hand-copies of the
same address were corrupted -- one extra character, then `K` in place of `k`.
Both were caught here. Neither would have been caught anywhere else.

Zero dependencies, so it runs anywhere the address might land.
"""

from __future__ import annotations

import hashlib
import sys

B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

NETWORKS = {
    73:  ("mainnet", "P2PKH", "W"),
    135: ("mainnet", "P2SH",  "w"),
    65:  ("testnet", "P2PKH", "T"),
    128: ("testnet", "P2SH",  "t"),
}


def decode(address: str):
    n = 0
    for ch in address:
        i = B58.find(ch)
        if i < 0:
            raise ValueError(
                f"{ch!r} is not a base58 character. Note that base58 has no "
                f"'0', 'O', 'I' or lowercase 'l' -- if you think you see one, "
                f"look again.")
        n = n * 58 + i

    raw = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    raw = b"\x00" * (len(address) - len(address.lstrip("1"))) + raw

    if len(raw) != 25:
        raise ValueError(f"decodes to {len(raw)} bytes, expected 25 "
                         f"(1 version + 20 hash + 4 checksum)")

    payload, checksum = raw[:-4], raw[-4:]
    expect = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    return payload, checksum == expect


def find_single_char_fix(bad: str) -> list[str]:
    """
    A 32-bit checksum makes a single-character slip recoverable: of ~1,900
    one-character variants, essentially only the intended address will pass.
    This does not replace re-reading the source -- it tells you what you most
    likely meant, which you then confirm against the original.
    """
    out = []
    for i in range(len(bad)):
        for c in B58:
            if c == bad[i]:
                continue
            cand = bad[:i] + c + bad[i + 1:]
            try:
                _, ok = decode(cand)
                if ok:
                    out.append((i + 1, bad[i], c, cand))
            except ValueError:
                pass
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    address = sys.argv[1].strip()

    print("=" * 70)
    print(" ADDRESS CHECK")
    print("=" * 70)
    print(f"  address : {address}")
    print(f"  length  : {len(address)}  (a WAM address is 34)")

    try:
        payload, ok = decode(address)
    except ValueError as exc:
        print(f"\n  REJECTED -- {exc}")
        return 1

    version = payload[0]
    net = NETWORKS.get(version)

    print(f"  checksum: {'valid' if ok else 'INVALID'}")
    print(f"  version : {version}" +
          (f"  ({net[0]} {net[1]}, starts with '{net[2]}')" if net else "  (not a WAM version)"))
    print(f"  hash160 : {payload[1:].hex()}")

    problems = []
    if not ok:
        problems.append("the checksum does not match -- at least one character is wrong")
    if net is None:
        problems.append(f"version byte {version} is not a WAM address version "
                        "(73/135 mainnet, 65/128 testnet)")
    if payload[1:] == b"\x00" * 20:
        problems.append("this is the BURN placeholder -- nobody holds its key. "
                        "Anything paid here is destroyed.")

    print()
    if not problems:
        print("  " + "=" * 66)
        print(f"  ACCEPTED -- valid {net[0]} {net[1]} address")
        print("  " + "=" * 66)
        print(f"  scriptPubKey: 76a914{payload[1:].hex()}88ac"
              if net[1] == "P2PKH" else
              f"  scriptPubKey: a914{payload[1:].hex()}87")
        return 0

    print("  " + "=" * 66)
    print("  REJECTED")
    print("  " + "=" * 66)
    for p in problems:
        print(f"    - {p}")

    if not ok:
        fixes = find_single_char_fix(address)
        print()
        if len(fixes) == 1:
            pos, was, now, cand = fixes[0]
            print(f"  Exactly one single-character correction passes the checksum:")
            print()
            print(f"      position {pos}:  {was!r}  ->  {now!r}")
            print(f"      {cand}")
            print()
            print("  That is almost certainly what you meant -- but CONFIRM it against")
            print("  the original source before using it. A valid address is not proof")
            print("  that it is YOUR address.")
        elif fixes:
            print(f"  {len(fixes)} different single-character corrections pass the")
            print("  checksum. Go back to the source; guessing is not acceptable here.")
        else:
            print("  No single-character correction works -- more than one character")
            print("  is wrong. Re-read the original.")

    return 1


if __name__ == "__main__":
    sys.exit(main())

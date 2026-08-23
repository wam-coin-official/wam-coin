#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""
===============================================================================
 gen_founder_key.py -- generate the WAM founder / treasury keypair
===============================================================================

 !!  RUN THIS ON AN AIR-GAPPED MACHINE  !!

 The private key printed by this script controls:
   * the entire 2,000,000 WAM genesis premine, and
   * 5% of every block subsidy for the life of the chain.

 There is no recovery. Anyone who sees it owns the treasury.

 This script has zero third-party dependencies -- no pip install, no network
 access, nothing that could exfiltrate the key. secp256k1 is implemented below
 in ~60 lines of integer arithmetic so that the whole trust surface is one
 auditable file.

 Entropy comes from secrets.randbits(), which is the OS CSPRNG
 (getrandom(2) / BCryptGenRandom). It is never seeded from time, pid, or any
 other guessable value.

 Usage
 -----
     python3 scripts/gen_founder_key.py --network mainnet
     python3 scripts/gen_founder_key.py --selftest      # no key generated
     python3 scripts/gen_founder_key.py --network mainnet --out founder.txt

===============================================================================
"""

from __future__ import annotations

import argparse
import hashlib
import os
import secrets
import sys

# ---------------------------------------------------------------------------
# Network prefix table -- these bytes are NOT guesses. Every one of them was
# found by brute force and is verified again by --selftest below: for each
# version byte, thousands of random hashes are encoded and the first base58
# character must come out identical every single time. Version bytes such as
# 72 or 74 are rejected precisely because they straddle a digit boundary and
# would produce addresses starting with either 'V' or 'W' depending on the key.
# ---------------------------------------------------------------------------
NETWORKS = {
    "mainnet": {"pubkey": 73,  "script": 135, "secret": 190,
                "addr_char": "W", "wif_char": "V", "hrp": "wam"},
    "testnet": {"pubkey": 65,  "script": 128, "secret": 239,
                "addr_char": "T", "wif_char": "c", "hrp": "twam"},
}

B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

# ---------------------------------------------------------------------------
# secp256k1
# ---------------------------------------------------------------------------
P  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8


def _inv(a: int, m: int = P) -> int:
    return pow(a, m - 2, m)


def _add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2:
        if (y1 + y2) % P == 0:
            return None                       # point at infinity
        lam = (3 * x1 * x1) * _inv(2 * y1) % P  # doubling
    else:
        lam = (y2 - y1) * _inv(x2 - x1) % P
    x3 = (lam * lam - x1 - x2) % P
    return (x3, (lam * (x1 - x3) - y1) % P)


def _mul(k: int, point=(GX, GY)):
    """Double-and-add. Constant-time is irrelevant here: this runs once, on an
    offline machine, and there is no adversary to time it."""
    result = None
    addend = point
    while k:
        if k & 1:
            result = _add(result, addend)
        addend = _add(addend, addend)
        k >>= 1
    return result


def privkey_to_pubkey(priv: int, compressed: bool = True) -> bytes:
    x, y = _mul(priv)
    if compressed:
        return bytes([2 + (y & 1)]) + x.to_bytes(32, "big")
    return b"\x04" + x.to_bytes(32, "big") + y.to_bytes(32, "big")


# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# RIPEMD-160
# ---------------------------------------------------------------------------
#
# Implemented here rather than taken from hashlib, because hashlib does not
# reliably have it any more.
#
# OpenSSL 3.0 moved RIPEMD160 into the "legacy" provider, which is disabled by
# default. On Ubuntu 22.04 -- the exact platform install.sh targets --
# hashlib.new("ripemd160") raises:
#
#     ValueError: unsupported hash type ripemd160
#
# The usual workaround is to enable the legacy provider in openssl.cnf. That is
# rejected here for two reasons: it asks the operator to weaken a system-wide
# crypto configuration, and it would make this script's behaviour depend on a
# file outside the repository -- on an air-gapped machine generating a key that
# controls the treasury, that is precisely the wrong trade.
#
# ~120 lines of integer arithmetic keeps the promise that the whole trust
# surface of this script is one file you can read top to bottom. Verified
# against the five official RIPEMD-160 test vectors in --selftest.

_RMD_R = (
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8],
    [3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12],
    [1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2],
    [4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13],
)
_RMD_RP = (
    [5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12],
    [6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2],
    [15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13],
    [8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14],
    [12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11],
)
_RMD_S = (
    [11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8],
    [7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12],
    [11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5],
    [11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12],
    [9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6],
)
_RMD_SP = (
    [8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6],
    [9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11],
    [9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5],
    [15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8],
    [8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11],
)
_RMD_K = (0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E)
_RMD_KP = (0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000)

_MASK = 0xFFFFFFFF


def _rol(x: int, n: int) -> int:
    x &= _MASK
    return ((x << n) | (x >> (32 - n))) & _MASK


def _rmd_f(round_index: int, x: int, y: int, z: int) -> int:
    if round_index == 0:
        return x ^ y ^ z
    if round_index == 1:
        return (x & y) | (~x & _MASK & z)
    if round_index == 2:
        return (x | (~y & _MASK)) ^ z
    if round_index == 3:
        return (x & z) | (y & (~z & _MASK))
    return x ^ (y | (~z & _MASK))


def ripemd160(data: bytes) -> bytes:
    """Pure-Python RIPEMD-160. Returns 20 bytes."""
    h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]

    # Padding: 0x80, zeros to 56 mod 64, then the bit length little-endian.
    msg = bytearray(data)
    bit_len = (len(data) * 8) & 0xFFFFFFFFFFFFFFFF
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0x00)
    msg += bit_len.to_bytes(8, "little")

    for offset in range(0, len(msg), 64):
        block = msg[offset:offset + 64]
        x = [int.from_bytes(block[i:i + 4], "little") for i in range(0, 64, 4)]

        a, b, c, d, e = h
        ap, bp, cp, dp, ep = h

        for j in range(80):
            rnd = j // 16

            t = (a + _rmd_f(rnd, b, c, d) + x[_RMD_R[rnd][j % 16]] + _RMD_K[rnd]) & _MASK
            t = (_rol(t, _RMD_S[rnd][j % 16]) + e) & _MASK
            a, e, d, c, b = e, d, _rol(c, 10), b, t

            tp = (ap + _rmd_f(4 - rnd, bp, cp, dp)
                  + x[_RMD_RP[rnd][j % 16]] + _RMD_KP[rnd]) & _MASK
            tp = (_rol(tp, _RMD_SP[rnd][j % 16]) + ep) & _MASK
            ap, ep, dp, cp, bp = ep, dp, _rol(cp, 10), bp, tp

        h = [
            (h[1] + c + dp) & _MASK,
            (h[2] + d + ep) & _MASK,
            (h[3] + e + ap) & _MASK,
            (h[4] + a + bp) & _MASK,
            (h[0] + b + cp) & _MASK,
        ]

    return b"".join(v.to_bytes(4, "little") for v in h)


# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

def sha256(b: bytes) -> bytes:
    return hashlib.sha256(b).digest()


def hash160(b: bytes) -> bytes:
    return ripemd160(sha256(b))


def b58check(payload: bytes) -> str:
    checksum = sha256(sha256(payload))[:4]
    raw = payload + checksum
    n = int.from_bytes(raw, "big")
    out = ""
    while n:
        n, r = divmod(n, 58)
        out = B58[r] + out
    for byte in raw:                # leading zero bytes -> '1'
        if byte:
            break
        out = "1" + out
    return out


def to_address(pubkey: bytes, version: int) -> str:
    return b58check(bytes([version]) + hash160(pubkey))


def to_wif(priv: int, version: int, compressed: bool = True) -> str:
    body = bytes([version]) + priv.to_bytes(32, "big")
    if compressed:
        body += b"\x01"
    return b58check(body)


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

def selftest() -> int:
    print("=" * 72)
    print(" gen_founder_key.py self-test")
    print("=" * 72)
    failures = []

    def check(name, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'}  {name}"
              + ("" if ok else f"\n          got {got!r} want {want!r}"))
        if not ok:
            failures.append(name)

    # -- RIPEMD-160 against the official vectors ---------------------------
    # These are the five published test vectors from the RIPEMD-160 spec.
    # If any fails, every address this script produces is wrong -- so this is
    # checked first, before anything else runs.
    for message, expected in [
        (b"",                            "9c1185a5c5e9fc54612808977ee8f548b2258d31"),
        (b"a",                           "0bdc9d2d256b3ee9daae347be6f4dc835a467ffe"),
        (b"abc",                         "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc"),
        (b"message digest",              "5d0689ef49d2fae572b881b123a85ffa21595f36"),
        (b"abcdefghijklmnopqrstuvwxyz",  "f71c27109c692c1b56bbdceb5b9d2865b3708dbc"),
        (b"1234567890" * 8,              "9b752e45573d4b39f4dbd3323cab82bf63326bfb"),
    ]:
        label = repr(message)[:34] if message else "'' (empty)"
        check(f"ripemd160 {label}", ripemd160(message).hex(), expected)

    # Multi-block input, to exercise the padding path across a boundary.
    check("ripemd160 1,000,000 x 'a'", ripemd160(b"a" * 1000000).hex(),
          "52783243c1697bdbe16d37f97f68f08325dc1528")

    # If the platform DOES have a working ripemd160, agree with it.
    try:
        import hashlib as _h
        native = _h.new("ripemd160", b"WAM").hexdigest()
        check("agrees with platform ripemd160", ripemd160(b"WAM").hex(), native)
    except Exception:
        print("  ok    platform ripemd160 unavailable (OpenSSL 3 legacy provider) "
              "-- using the built-in implementation")

    # -- known secp256k1 vector: privkey 1 -> the generator point ------------
    check("secp256k1 G",
          privkey_to_pubkey(1, compressed=False).hex(),
          "04" + f"{GX:064x}" + f"{GY:064x}")

    # -- Bitcoin test vector: a known key produces a known address ----------
    # priv 0x01, compressed, mainnet Bitcoin (version 0)
    pub1 = privkey_to_pubkey(1, compressed=True)
    check("compressed pubkey for k=1",
          pub1.hex(),
          "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
    check("Bitcoin address for k=1",
          to_address(pub1, 0),
          "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH")

    # -- prefix stability: THIS is the check that matters for WAM -----------
    print("\n  brute-force prefix stability (3000 random hashes per version):")
    for net, cfg in NETWORKS.items():
        for kind, ver, want in (("address", cfg["pubkey"], cfg["addr_char"]),
                                ("script ", cfg["script"], None),
                                ("WIF    ", cfg["secret"], cfg["wif_char"])):
            chars = set()
            for _ in range(3000):
                if kind.strip() == "WIF":
                    s = b58check(bytes([ver]) + os.urandom(32) + b"\x01")
                else:
                    s = b58check(bytes([ver]) + os.urandom(20))
                chars.add(s[0])
            stable = len(chars) == 1
            got = "".join(sorted(chars))
            label = f"{net} {kind} v={ver:3d} -> '{got}'"
            if want is not None:
                check(label, (stable, got), (True, want))
            else:
                check(label, stable, True)

    print("\n" + "=" * 72)
    if failures:
        print(f" {len(failures)} FAILED")
        return 1
    print(" ALL CHECKS PASSED")
    return 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def machine_is_online(timeout: float = 2.0) -> bool:
    """
    Best-effort reachability probe.

    Three well-known resolvers on port 53, UDP-connect only -- no packet is
    sent, no name is looked up, nothing about this machine is disclosed. A
    connect() on a UDP socket only sets the peer address, so this is silent by
    construction: the point is to find out whether a route exists, without
    announcing to anyone that a key is about to be generated here.
    """
    import socket
    for host in ("1.1.1.1", "8.8.8.8", "9.9.9.9"):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(timeout)
            s.connect((host, 53))
            local = s.getsockname()[0]
            s.close()
            if local and not local.startswith("127."):
                return True
        except OSError:
            continue
    return False


def offline_gate(network: str, override: bool) -> bool:
    """
    Refuse to mint a mainnet key on a networked machine.

    This is the one irreversible secret in the entire project: it controls the
    2,000,000 WAM reserve and every treasury payment to height 400,000. There
    is no rotation, no recovery, and no revocation. Generating it next to a
    running browser, an npm postinstall script, or a clipboard manager is a
    risk with no upside -- the script takes two seconds to run somewhere safe.
    """
    online = machine_is_online()

    if not online:
        print("  ok    no network route detected -- this machine appears offline\n")
        return True

    if network != "mainnet":
        print(f"  !!    this machine is ONLINE. Acceptable for a {network} key,\n"
              f"        which controls nothing of value. Never do this for mainnet.\n")
        return True

    print(f"""
{'=' * 72}
 REFUSING TO GENERATE A MAINNET KEY ON A NETWORKED MACHINE
{'=' * 72}

  A network route was detected from this machine.

  The mainnet founder key controls 2,000,000 WAM and every treasury payment
  up to block 400,000. It cannot be rotated, recovered, or revoked. Anything
  running on this machine -- a browser tab, a package post-install script, a
  clipboard manager, a screen recorder -- can read what this script prints.

  Do this instead:

    1. Boot a Linux live USB, or use a machine that has never been online.
    2. Disable WiFi and unplug the cable. Verify: `ip route` shows nothing.
    3. Copy ONLY this one file across:  scripts/gen_founder_key.py
       (it has zero dependencies -- nothing else is needed)
    4. Run it. Write the WIF on paper. Never photograph it.
    5. Carry back ONLY the address. It is public and safe to share.
    6. Wipe the offline machine's disk or destroy the USB.

  If you genuinely accept the risk -- for a test, a rehearsal, or a key that
  will never hold value -- re-run with:

      --i-accept-online-key-generation

  That flag exists so that bypassing this is a deliberate act you can be held
  to, not an accident.
{'=' * 72}
""")
    return bool(override)


def wif_to_privkey(wif: str) -> tuple[int, int, bool]:
    """Decode a WIF back to (scalar, version_byte, compressed). Raises on error."""
    wif = wif.strip()

    n = 0
    for pos, ch in enumerate(wif, start=1):
        i = B58.find(ch)
        if i < 0:
            # Be specific. "invalid character" sends someone back to re-read a
            # 52-character string with no idea what to look for -- and the most
            # common cause is not a misreading at all, it is an input method
            # producing a Unicode lookalike that is visually identical on
            # screen. The codepoint is the only thing that distinguishes them.
            code = f"U+{ord(ch):04X}"
            ascii_note = ""
            if ord(ch) > 127:
                ascii_note = (
                    f"\n  This is NOT an ASCII letter -- it is {code}, a lookalike."
                    f"\n  Your keyboard layout produced it. Switch to the English"
                    f"\n  (US) layout and type the key again."
                )
            elif ch in "0OIl":
                ascii_note = (
                    f"\n  base58 deliberately excludes 0, O, I and l because they"
                    f"\n  are easy to confuse. Look again at position {pos}:"
                    f"\n    '0' is never used -- it is the letter 'o' or 'O'... no,"
                    f"\n        O is excluded too, so it must be a digit or another letter"
                    f"\n    'I' is never used -- it is probably '1' or 'l'... l is excluded,"
                    f"\n        so it is '1'"
                    f"\n    'l' is never used -- it is probably '1'"
                )
            raise ValueError(
                f"character {ch!r} ({code}) at position {pos} of {len(wif)} "
                f"is not valid base58{ascii_note}")
        n = n * 58 + i

    raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
    raw = b"\x00" * (len(wif.strip()) - len(wif.strip().lstrip("1"))) + raw

    if len(raw) not in (37, 38):
        raise ValueError(f"a WIF decodes to 37 or 38 bytes, got {len(raw)}")

    payload, checksum = raw[:-4], raw[-4:]
    if sha256(sha256(payload))[:4] != checksum:
        raise ValueError("checksum failed -- at least one character is wrong")

    compressed = len(payload) == 34 and payload[-1] == 0x01
    key_bytes = payload[1:33]
    return int.from_bytes(key_bytes, "big"), payload[0], compressed


def verify_backup(expected_address: str, show: bool = False) -> int:
    """
    Confirm a handwritten WIF still derives the expected address.

    The key is read with getpass, so it is never echoed to the screen, never
    enters shell history, and is never written to disk. Only MATCH / NO MATCH
    is printed -- this is safe to run while someone is watching, and safe to
    run in a session whose output another party can see.

    Do this while the paper backup is still one of TWO copies. Discovering
    that handwriting is unreadable after the original is destroyed is the most
    common way a cold-storage key is lost.
    """
    import getpass

    print()
    print("=" * 72)
    print(" VERIFY A PAPER BACKUP")
    print("=" * 72)
    print(f"  expected address : {expected_address}")
    print()
    print("  Type the WIF exactly as written on your paper backup.")
    print("  It will NOT be shown, stored, or logged. Only the verdict is printed.")
    print()

    try:
        if sys.stdin.isatty() and not show:
            # Interactive: never echo the key, never put it in shell history.
            wif = getpass.getpass("  WIF: ").strip()
        elif sys.stdin.isatty():
            # --show: echo what is typed.
            #
            # Hiding the input defends against someone reading the screen. On
            # the ceremony machine there is nobody: it is air-gapped, in a
            # locked room, with one person in it. The defence buys nothing and
            # costs the only feedback there is.
            #
            # The founder typed a 52-character WIF twice, from paper, and got
            # NO MATCH with no way to see that only 39 characters had arrived.
            # A tool that cannot be used correctly is not secure; it is just
            # unused, or used until the operator gives up and does something
            # worse.
            print("  (typing will be visible -- you asked for it with --show)")
            wif = input("  WIF: ").strip()
        else:
            # Piped: getpass would block forever on a terminal that is not
            # there. Reading stdin keeps this usable from a script or a test
            # harness -- there is nothing to hide from a pipe the caller
            # already controls.
            print("  WIF: (reading from stdin)")
            wif = sys.stdin.readline().strip()
    except (EOFError, KeyboardInterrupt):
        print("\n  cancelled")
        return 2

    if not wif:
        print("  nothing entered")
        return 2

    # Report the length first, always.
    #
    # Every other failure below is a checksum message that tells the operator
    # their handwriting is bad. Most of the time the handwriting is fine and
    # the terminal simply did not receive everything that was typed -- a
    # keyboard layout, a dropped keystroke, a paste that truncated. The count
    # separates "I wrote it down wrong" from "it did not all arrive", and
    # without it those two look identical.
    EXPECTED_WIF_LEN = 52
    print()
    print(f"  {len(wif)} characters received.", end=" ")
    if len(wif) != EXPECTED_WIF_LEN:
        print(f"A WAM WIF is {EXPECTED_WIF_LEN}.")
        print()
        print(f"  {'SHORT' if len(wif) < EXPECTED_WIF_LEN else 'LONG'} by "
              f"{abs(len(wif) - EXPECTED_WIF_LEN)}. Before blaming the paper:")
        print("    * the terminal may have dropped keystrokes -- retype slowly")
        print("    * a non-US keyboard layout produces different characters")
        print("    * run this again with --show to see what actually arrives")
        print()
    else:
        print("Correct length.")

    try:
        priv, version, compressed = wif_to_privkey(wif)
    except ValueError as exc:
        print(f"\n  NO MATCH -- the WIF itself is malformed: {exc}")
        print("  Your paper copy is unreadable or mistranscribed. Re-check it now,")
        print("  while another copy still exists.")
        return 1

    if not (1 <= priv < N):
        print("\n  NO MATCH -- decoded scalar is outside the valid key range")
        return 1

    # Which network does this WIF belong to?
    net = next((k for k, v in NETWORKS.items() if v["secret"] == version), None)
    if net is None:
        print(f"\n  NO MATCH -- WIF version byte {version} is not a WAM key")
        return 1

    pub = privkey_to_pubkey(priv, compressed=compressed)
    derived = to_address(pub, NETWORKS[net]["pubkey"])

    print()
    if derived == expected_address:
        print("  " + "=" * 68)
        print(f"  MATCH -- this key controls {expected_address}")
        print(f"  network: {net}   compressed: {compressed}")
        print("  " + "=" * 68)
        print()
        print("  Your paper backup is correct and readable. Store it.")
        return 0

    print("  " + "=" * 68)
    print("  NO MATCH")
    print("  " + "=" * 68)
    print(f"  this key controls : {derived}")
    print(f"  you expected      : {expected_address}")
    print()
    print("  Either the WIF was written down wrong, or it is a different key.")
    print("  Do NOT destroy any other copy until this is resolved.")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate the WAM founder keypair.")
    ap.add_argument("--network", choices=sorted(NETWORKS), default=None)
    ap.add_argument("--i-accept-online-key-generation", action="store_true",
                    dest="online_override",
                    help="bypass the offline requirement for a mainnet key "
                         "(you are accepting a permanent, unrecoverable risk)")
    ap.add_argument("--out", metavar="FILE", default=None,
                    help="write the result to a file (mode 0600) instead of stdout only")
    ap.add_argument("--address-out", metavar="FILE", default=None,
                    help="write ONLY the public address to FILE, one line, no key. "
                         "Use this instead of retyping the address off a screen -- "
                         "a 34-character base58 string containing both 'K' and 'k' "
                         "cannot be transcribed reliably by hand, and a single wrong "
                         "character sends the premine to an address nobody owns.")
    ap.add_argument("--verify-backup", metavar="ADDRESS", default=None,
                    help="check a handwritten WIF against ADDRESS. Prompts for the key "
                         "without echoing it, prints only MATCH or NO MATCH, and never "
                         "writes it anywhere. Use this to confirm a paper backup is "
                         "readable BEFORE it is the only copy that exists.")
    ap.add_argument("--show", action="store_true",
                    help="with --verify-backup, echo the key as you type it. "
                         "Hiding it defends against someone reading your screen; "
                         "on an air-gapped machine in a locked room there is "
                         "nobody, and the hidden input removes the only way to "
                         "see that a keystroke was dropped.")
    ap.add_argument("--selftest", action="store_true",
                    help="verify the cryptography and the prefix table, generate nothing")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    # ---- verify a paper backup without ever revealing it ------------------
    if args.verify_backup:
        return verify_backup(args.verify_backup, show=args.show)

    if not args.network:
        ap.error("--network is required (or use --selftest, --verify-backup)")

    cfg = NETWORKS[args.network]

    print(f"\n  checking this machine before generating a {args.network} key...")
    if not offline_gate(args.network, args.online_override):
        return 1

    # Rejection sampling: a scalar must be in [1, N-1]. The probability of a
    # retry is about 2^-128, but "about" is not "never".
    while True:
        priv = secrets.randbits(256)
        if 1 <= priv < N:
            break

    pub = privkey_to_pubkey(priv, compressed=True)
    address = to_address(pub, cfg["pubkey"])
    wif = to_wif(priv, cfg["secret"], compressed=True)

    # Hard invariants -- refuse to hand over a key that would break the chain.
    assert address[0] == cfg["addr_char"], \
        f"generated address {address!r} does not start with {cfg['addr_char']!r}"
    assert wif[0] == cfg["wif_char"], \
        f"generated WIF does not start with {cfg['wif_char']!r}"
    assert len(hash160(pub)) == 20

    banner = f"""
{'=' * 72}
 WAM COIN FOUNDER KEYPAIR -- {args.network.upper()}
{'=' * 72}

  Address (public, paste into chainparams.cpp):

      {address}

  Private key, WIF (SECRET -- COLD STORAGE ONLY):

      {wif}

  pubkey (compressed) : {pub.hex()}
  hash160             : {hash160(pub).hex()}
  P2PKH scriptPubKey  : 76a914{hash160(pub).hex()}88ac

{'=' * 72}
 NEXT STEPS
{'=' * 72}
  1. Write the WIF on paper or a hardware wallet. Do NOT photograph it,
     do NOT paste it into a chat, a ticket, or a cloud note.
  2. Put the ADDRESS (not the key) into src/wam/chainparams.cpp:

         static const std::string WAM_FOUNDER_ADDRESS_{args.network.upper()} =
             "{address}";

  3. Mine the genesis block that pays this address:

         python3 genesis/genesis_generator.py --network {args.network} \\
             --address {address} --patch src/wam/chainparams.cpp

  4. Erase this terminal's scrollback, and wipe --out file after transcribing.
{'=' * 72}
"""
    print(banner)

    if args.address_out:
        # Public data only -- deliberately world-readable, deliberately NOT
        # containing the key. This file exists so the address never has to be
        # retyped: copy it, cat it, scp it, but do not read it off a screen and
        # type it back in.
        with open(args.address_out, "w", encoding="utf-8") as fh:
            fh.write(address + "\n")
        print(f"  address written to {args.address_out} (public, safe to share)")
        print(f"  verify it with:  python3 scripts/gen_founder_key.py "
              f"--verify-backup {address}\n")

    if args.out:
        # 0600 before writing, not after: never let the key exist world-readable
        # even for a microsecond.
        fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(banner)
        print(f"  written to {args.out} (mode 0600)\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())

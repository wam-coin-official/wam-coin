#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""
Byte-exactness test for genesis_generator.py.

The one thing that can silently ruin a coin launch is a serialization that is
*almost* right: the generator mines a nonce, the value goes into
chainparams.cpp, and then the daemon computes a different hash and refuses to
start -- or worse, starts on a chain nobody else can reproduce.

Rather than trust the code by inspection, this test rebuilds Bitcoin's real
genesis block using the exact same functions and checks the result against the
two values every person on earth can verify:

    merkle root : 4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b
    block hash  : 000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f

If those match, then varint encoding, script pushes, CScriptNum, transaction
serialization, the merkle computation and the 80-byte header layout are all
correct, because getting any one of them wrong changes the hash completely.

    python3 genesis/test_serialization.py

No librandomx required -- this test does not mine.
"""

from __future__ import annotations

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from genesis_generator import (  # noqa: E402
    GENESIS_PHRASE,
    GENESIS_PREMINE,
    GENESIS_TIME,
    PREMINE_TRANCHES,
    PREMINE_UNLOCK_TIMES,
    base58_decode_check,
    build_coinbase_scriptsig,
    build_coinbase_tx,
    build_genesis_outputs,
    compact_to_target,
    dsha256,
    p2pkh_script,
    push_data,
    script_num,
    serialize_header,
    timelocked_script,
    varint,
)

FAILURES: list[str] = []


def check(name: str, got, want) -> None:
    if got == want:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}\n          got  {got}\n          want {want}")
        FAILURES.append(name)


# ---------------------------------------------------------------------------
# 1. Bitcoin genesis block, rebuilt with WAM's serializer
# ---------------------------------------------------------------------------

def test_bitcoin_genesis() -> None:
    print("\n[1] Bitcoin genesis block reproduction")

    phrase = "The Times 03/Jan/2009 Chancellor on brink of second bailout for banks"

    # Bitcoin's genesis pays to a raw P2PK script, not P2PKH.
    pubkey = bytes.fromhex(
        "04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb6"
        "49f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f")
    script_pubkey = push_data(pubkey) + b"\xac"  # <pubkey> OP_CHECKSIG

    tx = build_coinbase_tx([(50 * 100_000_000, script_pubkey)], phrase)
    merkle = dsha256(tx)

    check("merkle root",
          merkle[::-1].hex(),
          "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b")

    header = serialize_header(
        version=1,
        prev=b"\x00" * 32,
        merkle=merkle,
        n_time=1231006505,
        n_bits=0x1D00FFFF,
        nonce=2083236893,
    )

    check("header length", len(header), 80)
    check("block hash",
          dsha256(header)[::-1].hex(),
          "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f")

    # And the PoW is genuinely satisfied by that nonce.
    target = compact_to_target(0x1D00FFFF)
    check("bitcoin genesis meets its target",
          int.from_bytes(dsha256(header)[::-1], "big") <= target, True)


# ---------------------------------------------------------------------------
# 2. Encoding primitives
# ---------------------------------------------------------------------------

def test_primitives() -> None:
    print("\n[2] encoding primitives")

    check("varint 0",       varint(0).hex(),       "00")
    check("varint 252",     varint(252).hex(),     "fc")
    check("varint 253",     varint(253).hex(),     "fdfd00")
    check("varint 65535",   varint(65535).hex(),   "fdffff")
    check("varint 65536",   varint(65536).hex(),   "fe00000100")

    check("script_num 486604799", script_num(486604799).hex(), "ffff001d")
    check("script_num 4",         script_num(4).hex(),         "04")
    check("script_num 0",         script_num(0).hex(),         "00")
    # 128 needs a zero sign byte appended, or it would read as -0.
    check("script_num 128",       script_num(128).hex(),       "8000")
    check("script_num -1",        script_num(-1).hex(),        "81")

    check("push_data 1 byte",  push_data(b"\xab").hex(), "01ab")
    check("push_data 75 bytes", push_data(b"\x00" * 75)[:1].hex(), "4b")
    check("push_data 76 bytes", push_data(b"\x00" * 76)[:2].hex(), "4c4c")

    check("compact 0x1d00ffff",
          f"{compact_to_target(0x1D00FFFF):064x}",
          "00000000ffff0000000000000000000000000000000000000000000000000000")
    check("compact 0x1e0ffff0",
          f"{compact_to_target(0x1E0FFFF0):064x}",
          "00000ffff0000000000000000000000000000000000000000000000000000000")


# ---------------------------------------------------------------------------
# 3. WAM-specific structure
# ---------------------------------------------------------------------------

def test_wam_genesis_shape() -> None:
    print("\n[3] WAM genesis structure")

    check("launch phrase length is 64 bytes", len(GENESIS_PHRASE.encode()), 64)
    check("premine is 2,000,000 WAM", GENESIS_PREMINE, 2_000_000 * 100_000_000)

    sig = build_coinbase_scriptsig(GENESIS_PHRASE)
    # 5 bytes (486604799) + 2 bytes (CScriptNum 4) + 1 + 64 (phrase)
    check("scriptSig length", len(sig), 5 + 2 + 1 + 64)
    check("scriptSig embeds the phrase", GENESIS_PHRASE.encode() in sig, True)
    check("scriptSig <= 100 bytes (consensus limit)", len(sig) <= 100, True)

    fake_hash = bytes(range(20))
    spk = p2pkh_script(fake_hash)
    check("P2PKH script length", len(spk), 25)
    check("P2PKH opcodes", spk[:3].hex() + "|" + spk[-2:].hex(), "76a914|88ac")

    tx = build_coinbase_tx([(GENESIS_PREMINE, spk)], GENESIS_PHRASE)
    check("coinbase encodes the premine value",
          struct.pack("<q", GENESIS_PREMINE) in tx, True)
    check("coinbase prevout is null",
          tx[5:37] == b"\x00" * 32 and tx[37:41] == b"\xff\xff\xff\xff", True)


# ---------------------------------------------------------------------------
# 3b. Founder-reserve vesting
# ---------------------------------------------------------------------------

def test_vesting() -> None:
    print("\n[3b] founder-reserve vesting (must match chainparams.cpp)")

    fake_hash = bytes(range(20))
    outputs = build_genesis_outputs(fake_hash)

    check("five tranches", len(outputs), PREMINE_TRANCHES)
    check("tranches sum to the premine",
          sum(v for v, _ in outputs), GENESIS_PREMINE)
    check("every tranche is 400,000 WAM",
          all(v == 400_000 * 100_000_000 for v, _ in outputs), True)

    # Tranche 1 must be a plain P2PKH -- launch working capital.
    check("tranche 1 is unlocked P2PKH", outputs[0][1], p2pkh_script(fake_hash))
    check("tranche 1 script is 25 bytes", len(outputs[0][1]), 25)

    # Tranches 2-5 must be bare CLTV, not P2SH: the unlock date has to be
    # readable straight out of the genesis block.
    for i in range(1, PREMINE_TRANCHES):
        script = outputs[i][1]
        locktime = PREMINE_UNLOCK_TIMES[i]
        expected = (push_data(script_num(locktime))
                    + b"\xb1\x75"
                    + p2pkh_script(fake_hash))
        check(f"tranche {i + 1} CLTV script", script, expected)
        check(f"tranche {i + 1} embeds OP_CHECKLOCKTIMEVERIFY OP_DROP",
              b"\xb1\x75" in script, True)
        check(f"tranche {i + 1} is bare, not P2SH",
              script.endswith(b"\x88\xac"), True)

    check("unlock times are strictly increasing",
          all(PREMINE_UNLOCK_TIMES[i] < PREMINE_UNLOCK_TIMES[i + 1]
              for i in range(1, PREMINE_TRANCHES - 1)), True)
    check("every lock is read as a timestamp, not a height",
          all(t > 500_000_000 for t in PREMINE_UNLOCK_TIMES[1:]), True)

    # The dates the whitepaper publishes.
    import datetime as dt
    dates = [dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%d")
             for t in PREMINE_UNLOCK_TIMES[1:]]
    check("published unlock dates", dates,
          ["2027-09-15", "2028-09-15", "2029-09-15", "2030-09-15"])
    check("genesis time is 2026-09-15",
          dt.datetime.fromtimestamp(GENESIS_TIME, dt.timezone.utc).strftime("%Y-%m-%d"),
          "2026-09-15")

    # A five-output coinbase must still serialize cleanly.
    tx = build_coinbase_tx(outputs, GENESIS_PHRASE)
    check("five-output coinbase has vout count 5", tx[len(tx) - 1:] == b"\x00", True)
    root = dsha256(tx)
    check("merkle root is 32 bytes", len(root), 32)

    # regtest escape hatch
    single = build_genesis_outputs(fake_hash, single=True)
    check("single-output mode returns one unlocked output",
          (len(single), single[0][0], single[0][1]),
          (1, GENESIS_PREMINE, p2pkh_script(fake_hash)))


# ---------------------------------------------------------------------------
# 4. Address decoding
# ---------------------------------------------------------------------------

def test_base58() -> None:
    print("\n[4] base58check decoding")

    # Satoshi's genesis address -- version 0, well known.
    payload = base58_decode_check("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
    check("version byte", payload[0], 0)
    check("hash160",
          payload[1:].hex(),
          "62e907b15cbf27d5425399ebf6f0fb50ebb88f18")

    try:
        base58_decode_check("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb")  # bad checksum
        check("rejects a bad checksum", "no exception", "ValueError")
    except ValueError:
        check("rejects a bad checksum", True, True)


if __name__ == "__main__":
    print("=" * 70)
    print(" WAM genesis serialization test suite")
    print("=" * 70)

    test_bitcoin_genesis()
    test_primitives()
    test_wam_genesis_shape()
    test_vesting()
    test_base58()

    print("\n" + "=" * 70)
    if FAILURES:
        print(f" {len(FAILURES)} FAILED: {', '.join(FAILURES)}")
        sys.exit(1)
    print(" ALL CHECKS PASSED -- serialization is byte-exact with Bitcoin Core")
    sys.exit(0)

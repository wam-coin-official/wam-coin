#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""
===============================================================================
 check_vesting_sync.py -- the founder vesting schedule exists in three files
===============================================================================

 The premine unlock times are written out in three places:

     src/wam/wam-params.h         the consensus rule, and the only authority
     genesis/genesis_generator.py the miner that builds the genesis block
     explorer/lib/constants.js    what the public is shown

 They cannot share one definition: a Python miner cannot read a C++ header at
 run time, and neither can a Node explorer. So they are copies, and copies rot.

 What rotting costs here, in order of how quietly it happens:

   * The generator disagreeing with the header produces a genesis block whose
     hash the node then rejects. Loud, immediate, and unmissable -- the chain
     simply will not start.

   * The explorer disagreeing with the header is silent and much worse. The
     page showing a schedule the chain does not enforce is read by exactly the
     people who came to verify rather than trust, and a wrong number there is
     indistinguishable from a lie.

 This script compares all three and exits non-zero on any difference. It is
 cheap enough to run on every commit and answers a question no reviewer can
 answer by reading one file.

     python3 scripts/check_vesting_sync.py

===============================================================================
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# CLTV reads a value below this as a block height rather than a Unix time. A
# lock under it would be satisfied within hours of launch while still looking
# like a multi-year lock to anyone reading the number.
CLTV_TIME_THRESHOLD = 500_000_000

SOURCES = [
    ("wam-params.h",         "src/wam/wam-params.h",
     r"WAM_PREMINE_UNLOCK_TIMES\[[^\]]*\]\s*=\s*\{(.*?)\}"),
    ("genesis_generator.py", "genesis/genesis_generator.py",
     r"PREMINE_UNLOCK_TIMES\s*=\s*\[(.*?)\]"),
    ("explorer constants",   "explorer/lib/constants.js",
     r"PREMINE_UNLOCK_TIMES:\s*\[(.*?)\]"),
]


def strip_comments(text: str) -> str:
    """Remove // and # comments so a date in a comment is never read as a value."""
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r"#[^\n]*", "", text)
    return text


def read_table(path: pathlib.Path, pattern: str) -> list[int]:
    if not path.exists():
        raise SystemExit(f"missing file: {path}")
    body = path.read_text(encoding="utf-8")
    m = re.search(pattern, body, re.S)
    if not m:
        raise SystemExit(f"could not find the unlock table in {path}")
    return [int(v) for v in re.findall(r"\b\d{4,}\b", strip_comments(m.group(1)))]


def main() -> int:
    print("=" * 70)
    print(" FOUNDER VESTING -- are all copies the same?")
    print("=" * 70)

    tables: dict[str, list[int]] = {}
    for label, rel, pattern in SOURCES:
        table = read_table(ROOT / rel, pattern)
        tables[label] = table
        print(f"  {label:<22} {len(table)} tranches")
        for i, t in enumerate(table, 1):
            print(f"      {i}. {t}")
        print()

    authority = tables["wam-params.h"]
    failures = []

    for label, table in tables.items():
        if table != authority:
            failures.append(f"{label} does not match wam-params.h:\n"
                            f"      header: {authority}\n"
                            f"      {label}: {table}")

    if len(authority) != 5:
        failures.append(f"expected 5 tranches, found {len(authority)}")

    for i, t in enumerate(authority, 1):
        if t <= CLTV_TIME_THRESHOLD:
            failures.append(
                f"tranche {i} unlock time {t} is not above the CLTV time threshold "
                f"({CLTV_TIME_THRESHOLD}). A value below it is read as a BLOCK HEIGHT, "
                f"so those coins would unlock within hours of launch while the number "
                f"still looks like a date. None of the reserve may be liquid at launch.")

    if authority != sorted(authority):
        failures.append("the unlock times are not in ascending order")

    print("-" * 70)
    if failures:
        for f in failures:
            print(f"  FAIL  {f}")
        print("-" * 70)
        return 1

    print("  ok    all three copies agree")
    print("  ok    every tranche carries a real time lock; none is liquid at launch")
    print("  ok    the schedule is in ascending order")
    print("-" * 70)
    return 0


if __name__ == "__main__":
    sys.exit(main())

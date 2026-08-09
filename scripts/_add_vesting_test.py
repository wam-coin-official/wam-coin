#!/usr/bin/env python3
"""
One-off: add wam_vesting_tests.cpp to an ALREADY-patched tree.

patch_upstream.py is idempotent by marker, so the BITCOIN_TESTS edit is skipped
on a tree where it has already run -- which means an already-built tree never
picks up a newly added test file. A fresh tree gets it from the patcher; this
brings an existing one up to date without a full re-clone.

    python3 scripts/_add_vesting_test.py build/wam-core
"""
import io
import sys

NEW = "  test/wam_vesting_tests.cpp \\\n"
ANCHOR = "  test/wam_devfee_tests.cpp \\\n"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    path = f"{sys.argv[1]}/src/Makefile.test.include"
    src = io.open(path, encoding="utf-8").read()

    if NEW in src:
        print("  already present")
        return 0

    if ANCHOR not in src:
        print(f"  anchor not found in {path}")
        return 1

    io.open(path, "w", encoding="utf-8").write(src.replace(ANCHOR, ANCHOR + NEW, 1))
    print("  added test/wam_vesting_tests.cpp to BITCOIN_TESTS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

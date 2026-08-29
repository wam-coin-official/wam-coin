#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_listing_entry.py -- does the Komodo entry still describe this coin?
# ===========================================================================
#
#      python3 scripts/check_listing_entry.py
#
#  WHY THIS EXISTS
#
#  A listing entry is read by software, not by a person. A wrong `pubtype`
#  does not look wrong on the page -- it sends somebody's coins nowhere, and
#  the first report of it is a user who has already lost them.
#
#  The entry was written by hand from the source, and hand-written copies of
#  constants drift. Every one of these numbers already exists exactly once in
#  src/wam, so the entry can be checked against it rather than trusted, and
#  the check can run in the sweep rather than at submission time -- because
#  the dangerous moment is not the day it is written, it is the day somebody
#  changes a prefix and forgets that a file in integration/ repeats it.
# ===========================================================================

import json
import pathlib
import re
import sys

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"

REPO = pathlib.Path(__file__).resolve().parent.parent
KOMODO = REPO / "integration" / "komodo"

_fails = []


def ok(m):   print(f"  {GRN}ok{OFF}    {m}")
def bad(m):  print(f"  {RED}FAIL{OFF}  {m}"); _fails.append(m)
def warn(m): print(f"  {YEL}!!{OFF}    {m}")


def main():
    entry = json.loads((KOMODO / "coin-entry.json").read_text(encoding="utf-8"))
    if isinstance(entry, list):
        entry = entry[0]
    cp = (REPO / "src/wam/chainparams.cpp").read_text(encoding="utf-8")
    hdr = (REPO / "src/wam/wam-params.h").read_text(encoding="utf-8")

    # Only the mainnet section. Testnet repeats every one of these constants
    # with different values, and a check that reads the wrong section passes
    # for the wrong reason.
    main_section = cp[cp.index("CMainParams"):cp.index("CTestNetParams")]

    def num(pat, text):
        m = re.search(pat, text)
        return int(m.group(1).replace("'", "")) if m else None

    def prefix(name):
        return num(r"base58Prefixes\[%s\][^;]*?\(1,\s*([0-9]+)\)" % name,
                   main_section)

    coin_type = re.search(r"WAM_BIP44_COIN_TYPE[^=]*=\s*(0x[0-9A-Fa-f]+)", hdr)
    coin_type = int(coin_type.group(1), 16) if coin_type else None
    hrp = re.search(r'bech32_hrp\s*=\s*"([a-z]+)"', main_section)

    print(f"{BLD}every field of the Komodo entry, against src/wam{OFF}")

    checks = [
        ("coin",                   entry.get("coin"), "WAM"),
        ("pubtype",                entry.get("pubtype"), prefix("PUBKEY_ADDRESS")),
        ("p2shtype",               entry.get("p2shtype"), prefix("SCRIPT_ADDRESS")),
        ("wiftype",                entry.get("wiftype"), prefix("SECRET_KEY")),
        ("bech32_hrp",             entry.get("bech32_hrp"),
                                   hrp.group(1) if hrp else None),
        ("avg_blocktime",          entry.get("avg_blocktime"),
                                   num(r"WAM_POW_TARGET_SPACING[^=]*=\s*([0-9']+)", hdr)),
        ("derivation_path",        entry.get("derivation_path"),
                                   f"m/44'/{coin_type}'"),
        ("protocol.type",          entry.get("protocol", {}).get("type"), "UTXO"),
    ]

    for name, got, want in checks:
        if want is None:
            bad(f"{name}: could not find the value in src/wam to compare against")
        elif str(got) != str(want):
            bad(f"{name}: entry says {got!r}, source says {want!r}")
        else:
            ok(f"{name:<18} {got}")

    # Not derived from source -- a judgement, recorded so a later change is
    # deliberate rather than accidental. See integration/komodo/NOTES.md.
    rc = entry.get("required_confirmations")
    if rc != 20:
        bad(f"required_confirmations is {rc}. It was set to 20 on 2026-08-29 "
            f"because this is a new RandomX chain and the cost of reversing a "
            f"confirmation is set by hashrate, not block timing. Changing it "
            f"is a decision, not a typo -- update NOTES.md with the reason.")
    else:
        ok(f"{'required_confirmations':<18} 20  (a judgement, not a constant)")

    # Fields comparable entries carry. Missing one is not fatal, but it is
    # the kind of omission a reviewer notices and we would rather not.
    expected = {"coin", "name", "fname", "rpcport", "pubtype", "p2shtype",
                "wiftype", "txfee", "dust", "segwit", "bech32_hrp", "mm2",
                "required_confirmations", "avg_blocktime", "protocol",
                "derivation_path", "links", "wallet_only",
                "sign_message_prefix"}
    missing = sorted(expected - set(entry))
    if missing:
        warn(f"fields other entries carry and this one does not: {', '.join(missing)}")
    else:
        ok("no field missing that comparable entries carry")

    # The Electrum file publishes the mainnet ports. If it ever names the
    # testnet set, a wallet would be pointed at the wrong chain -- which is
    # exactly the state that was corrected on 2026-08-29.
    el = json.loads((KOMODO / "electrums-WAM.json").read_text(encoding="utf-8"))
    for s in el:
        url = s.get("url", "")
        ws = s.get("ws_url", "")
        if ":50002" not in url or ":50004" not in ws:
            bad(f"electrum entry {url} / {ws} does not use the published "
                f"mainnet ports 50002 and 50004")
    if not _fails:
        ok(f"{len(el)} electrum server(s), all on the published mainnet ports")

    print()
    if _fails:
        print(f"  {RED}{len(_fails)} field(s) disagree with the source{OFF}")
        return 1
    print(f"  {GRN}the entry describes this coin{OFF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

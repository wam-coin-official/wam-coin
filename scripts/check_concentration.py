#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_concentration.py -- how much of the chain is one party writing?
# ===========================================================================
#
#      python3 scripts/check_concentration.py --node HOST --network mainnet
#
#  WHY THIS EXISTS
#
#  Nineteen minutes after mainnet opened, 77 of the first 79 blocks had been
#  found by ONE payout address -- 97.5% -- and nothing we had written asked
#  the question. Fifty-four checks looked at units, clocks, ports, configs,
#  binaries, backups, peers and payouts; not one of them looked at who was
#  writing the chain.
#
#  That is the number that decides whether the chain can be rewritten at
#  will. It is also the number the founder had already acted on: he deferred
#  accepting WAM as payment on his own platform for fear of exactly this, and
#  he was right to.
#
#  WHAT IT MEASURES, AND WHAT IT CANNOT
#
#  It reads the coinbase of every block in a window and takes the LARGEST
#  output -- the miner's 47.5 WAM, never the treasury's 2.5, which is
#  excluded by address as well. Blocks are then counted per address.
#
#  One address is not one person. A pool pays its own address and distributes
#  to its miners, so the COINS spread while the HASH RATE stays under one
#  operator's hand. That is the honest reading, and it is the dangerous half:
#  a 51% attack needs one operator's decision, not one holder's balance.
#
#  Nor is a large share an accusation. A pool that shows up on day one with a
#  real farm, runs the published code and pays the treasury on every block is
#  doing nothing wrong. The risk is arithmetic and exists whatever anybody
#  intends, which is why this prints numbers and not adjectives.
#
#  EXIT CODES, this project's convention
#
#      0  no single party holds more than --warn of the window
#      1  one party is at or above --fail: the chain can be rewritten by one
#         decision, and deposits should not be trusted at shallow depth
#      2  the question could not be put -- no node answered, or too few
#         blocks to say anything. NOT a pass.
# ===========================================================================

import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wamcli import flags as _wamcli_flags          # noqa: E402

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"

# The treasury output is consensus, not a miner's reward. Excluded by address
# as well as by size, so a future subsidy halving that makes 2.5 the larger
# of the two cannot silently turn the treasury into "the biggest miner".
TREASURY = {
    "mainnet": "WdMMqW1DcgWZ6HtyJuEMdce6QkKg4raGmE",
    "testnet": None,
}


def rsh(host, cmd, timeout=120):
    if not host:
        p = subprocess.run(["bash", "-lc", cmd], capture_output=True,
                           text=True, timeout=timeout)
    else:
        p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                            f"root@{host}", cmd],
                           capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--node", help="ssh host running the node; omit to ask this machine")
    ap.add_argument("--network", default="mainnet",
                    choices=["mainnet", "testnet", "regtest"])
    ap.add_argument("--window", type=int, default=144,
                    help="how many of the most recent blocks to read (default 144, "
                         "about 4.8 hours at 120s)")
    ap.add_argument("--warn", type=float, default=35.0,
                    help="say something above this share, in percent")
    ap.add_argument("--fail", type=float, default=50.0,
                    help="a finding at or above this share, in percent")
    ap.add_argument("--min-blocks", type=int, default=20,
                    help="below this many blocks the window says nothing; exit 2")
    a = ap.parse_args()

    flag = _wamcli_flags(a.network)
    cli = f"wam-cli {flag}"
    print(f"\n{BLD}who is writing this chain?{OFF}")

    rc, out, err = rsh(a.node, f"{cli} getblockcount")
    if rc != 0 or not out.strip().isdigit():
        print(f"  {YEL}??{OFF}    no height from the node "
              f"({(err or out or 'no answer').splitlines()[0][:90]}). "
              f"Nothing was measured.")
        print()
        return 2
    tip = int(out.strip())

    first = max(1, tip - a.window + 1)          # never block 0: it has no miner
    count = tip - first + 1
    if count < a.min_blocks:
        print(f"  {YEL}??{OFF}    only {count} block(s) exist above genesis; "
              f"{a.min_blocks} are needed before a share means anything.")
        print()
        return 2

    # One round trip for the whole window. Asking per block over ssh takes
    # longer than the window it is measuring once the chain is a day old.
    #
    # The parser is written to a file on the far side rather than passed to
    # `python3 -c "..."`. An inline program has to survive this shell, ssh,
    # and the remote shell, and the first attempt did not: the newlines in it
    # arrived as literal backslash-n and every block came back a traceback,
    # which this check correctly reported as "read 0 of 81" and exit 2 rather
    # than as a clean chain. A heredoc with a quoted delimiter is passed
    # through untouched.
    treasury = TREASURY.get(a.network)
    remote = (
        "cat > /tmp/wam_finder.py <<'WAMEOF'\n"
        "import json, sys\n"
        "treasury = sys.argv[1] if len(sys.argv) > 1 else ''\n"
        "b = json.load(sys.stdin)\n"
        "outs = [o for o in b['tx'][0]['vout']\n"
        "        if o['scriptPubKey'].get('address') != treasury]\n"
        "print(max(outs, key=lambda o: o['value'])['scriptPubKey'].get('address', '?')\n"
        "      if outs else '?')\n"
        "WAMEOF\n"
        f"for h in $(seq {first} {tip}); do "
        f"{cli} getblock $({cli} getblockhash $h) 2 2>/dev/null | "
        f"python3 /tmp/wam_finder.py {json.dumps(treasury or '')}; done"
    )
    rc, out, err = rsh(a.node, remote, timeout=600)
    finders = [l.strip() for l in out.splitlines() if l.strip()]
    if len(finders) < a.min_blocks:
        print(f"  {YEL}??{OFF}    read {len(finders)} of {count} block(s) "
              f"({(err or 'no reason given').splitlines()[0][:70]}). "
              f"Too few to say anything.")
        print()
        return 2

    tally = {}
    for f in finders:
        tally[f] = tally.get(f, 0) + 1
    ranked = sorted(tally.items(), key=lambda kv: -kv[1])
    total = len(finders)
    top_addr, top_n = ranked[0]
    top_pc = 100.0 * top_n / total

    print(f"  window: blocks {first}..{tip} ({total} read), "
          f"{len(ranked)} distinct finder(s)")
    for addr, n in ranked[:5]:
        pc = 100.0 * n / total
        mark = f"{RED}FAIL{OFF}" if pc >= a.fail else (
               f"{YEL}!!{OFF}  " if pc >= a.warn else f"{GRN}ok{OFF}  ")
        # Addresses are redacted the way the pool API redacts them: the
        # question is concentration, not identity, and a list of who mines
        # what is a list of who gets attacked.
        short = addr if len(addr) <= 16 else f"{addr[:10]}...{addr[-4:]}"
        print(f"  {mark}  {short:<20} {n:>5} block(s)  {pc:5.1f}%")

    print()
    if top_pc >= a.fail:
        print(f"  {RED}one party wrote {top_pc:.1f}% of the last {total} blocks{OFF}")
        print("  At this share the chain can be reorganised by one decision. Nobody")
        print("  need intend it: deposits at shallow depth are not safe, and the")
        print("  only remedy is hash rate somewhere else -- more pools, and miners")
        print("  spread across them.\n")
        return 1
    if top_pc >= a.warn:
        print(f"  {YEL}the largest single finder holds {top_pc:.1f}%{OFF}")
        print("  Not yet a majority, and worth watching rather than announcing.\n")
        return 0
    print(f"  {GRN}no single party wrote more than {top_pc:.1f}% "
          f"of the last {total} blocks{OFF}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

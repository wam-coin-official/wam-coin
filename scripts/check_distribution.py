#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_distribution.py -- who ended up holding the coins?
# ===========================================================================
#
#      python3 scripts/check_distribution.py [--node HOST] [--network mainnet]
#
#  WHY THIS EXISTS
#
#  For the first three days this project measured concentration one way: the
#  share of BLOCKS found by one payout address. On 17 September that number
#  was 72%, and everything published about the chain -- the explorer, the ops
#  panel, four channels, a forum thread -- was built on it.
#
#  The founder said the reading was incomplete, and he was right. A pool's
#  payout address is not a holder; it is a pass-through. It receives the
#  coinbase, takes its fee, and pays the miners. So a chain can have 72% of
#  its blocks found through one address while the COINS are spread across
#  hundreds of people. Measured the same day: 544 addresses had received WAM.
#
#  Both numbers matter and they answer different questions:
#
#    block share  -> can one operator reorganise the chain (reorg risk, and
#                    the reason an exchange should require depth)
#    coin share   -> did the issuance actually reach many hands (which is
#                    what "fair distribution" means to anybody reading it)
#
#  Nothing measured the second one until this file. It is the one that was
#  being assumed, in both directions, by everyone including us.
#
#  HOW
#
#  Every output of every transaction is tallied by address: what each address
#  has ever RECEIVED. Not a balance -- balances need spend tracking, and a
#  received-total cannot be argued with. Addresses that appear as the largest
#  output of a coinbase are marked as pool pass-throughs, because that is
#  exactly what a pool payout address is, and the distribution is reported
#  twice: with them and without.
#
#  State is kept so each run only reads new blocks. A full scan of 1,741
#  blocks takes about two minutes; by the end of a month it would be half an
#  hour, and an hourly check that takes half an hour is a check nobody runs.
#
#  EXIT CODES, this project's convention
#
#      0  measured
#      2  could not be measured -- no node answered, or too few blocks
# ===========================================================================

import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wamcli import flags as _wamcli_flags          # noqa: E402

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"
COIN = 100_000_000


def run(host, cmd, timeout=180):
    if host:
        argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                f"root@{host}", cmd]
    else:
        argv = ["bash", "-lc", cmd]
    p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


REMOTE = r'''
import json, subprocess, sys
cli = sys.argv[1].split()
start = int(sys.argv[2])
state_path = sys.argv[3]

def sh(*a):
    return subprocess.run(cli + list(a), capture_output=True, text=True).stdout

try:
    state = json.load(open(state_path))
except Exception:
    state = {"height": 0, "recv": {}, "pools": []}

recv = state.get("recv", {})
pools = set(state.get("pools", []))
tip = int(sh("getblockcount") or 0)
first = max(state.get("height", 0) + 1, 0)

# Genesis is included on a first run: its five outputs are the premine, and a
# distribution figure that omits two million coins is not a distribution
# figure.
if state.get("height", 0) == 0:
    first = 0

for h in range(first, tip + 1):
    bh = sh("getblockhash", str(h)).strip()
    if not bh:
        continue
    try:
        b = json.loads(sh("getblock", bh, "2"))
    except Exception:
        continue
    txs = b.get("tx", [])
    for i, tx in enumerate(txs):
        outs = tx.get("vout", [])
        if i == 0 and outs:
            # The largest coinbase output is the miner's, and on this chain a
            # miner that pays others is a pool. Marked, never excluded from
            # the raw tally.
            big = max(outs, key=lambda o: o["value"])
            a = big["scriptPubKey"].get("address")
            if a:
                pools.add(a)
        for o in outs:
            a = o["scriptPubKey"].get("address")
            if a:
                recv[a] = recv.get(a, 0) + int(round(o["value"] * 1e8))

state = {"height": tip, "recv": recv, "pools": sorted(pools)}
try:
    json.dump(state, open(state_path, "w"))
except Exception as e:
    print("STATE_WRITE_FAILED " + str(e), file=sys.stderr)

print(json.dumps({"height": tip, "recv": recv, "pools": sorted(pools)}))
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--node", help="ssh host running the node; omit to ask this machine")
    ap.add_argument("--network", default="mainnet",
                    choices=["mainnet", "testnet", "regtest"])
    ap.add_argument("--state", default="/var/lib/wam-distribution/state.json")
    ap.add_argument("--top", type=int, default=8)
    a = ap.parse_args()

    cli = f"wam-cli {_wamcli_flags(a.network)}"
    print(f"\n{BLD}who ended up holding the coins?{OFF}")

    prep = (f"mkdir -p {os.path.dirname(a.state)} 2>/dev/null; "
            f"cat > /tmp/wam_dist_scan.py <<'WAMEOF'\n{REMOTE}\nWAMEOF\n"
            f"python3 /tmp/wam_dist_scan.py '{cli}' 0 {a.state}")
    rc, out, err = run(a.node, prep, timeout=900)
    if rc != 0 or not out:
        first = (err or out or "no answer").splitlines()
        print(f"  {YEL}??{OFF}    the chain could not be read "
              f"({first[0][:90] if first else 'no answer'}). Nothing measured.")
        print()
        return 2

    try:
        d = json.loads(out.splitlines()[-1])
    except Exception as e:
        print(f"  {YEL}??{OFF}    the reply could not be parsed ({e}).")
        print()
        return 2

    recv = d["recv"]
    pools = set(d["pools"])
    if len(recv) < 2:
        print(f"  {YEL}??{OFF}    only {len(recv)} address(es) seen; too early to say.")
        print()
        return 2

    total = sum(recv.values())
    ranked = sorted(recv.items(), key=lambda kv: -kv[1])
    end = [(k, v) for k, v in ranked if k not in pools]
    end_total = sum(v for _, v in end)

    print(f"  height {d['height']}  --  {len(recv)} address(es) have ever received WAM")
    print(f"  {len(pools)} of them are pool pass-throughs "
          f"(the largest output of a coinbase they found)")
    # WHAT THIS DOES NOT COUNT, said before the numbers rather than after.
    #
    # The 2,000,000 WAM premine sits in five genesis outputs whose scripts are
    # bare <locktime> OP_CHECKLOCKTIMEVERIFY OP_DROP <p2pkh>. That is not a
    # standard script, so wam-cli reports no `address` for them and they never
    # enter this tally. Every figure below therefore describes the coins MINED
    # since block 1 and nothing else -- the right denominator for "did the
    # issuance reach many hands", and the wrong one for "who owns WAM". The
    # premine is locked by consensus until 2027-09-15 and anybody can verify
    # that from block 0.
    print("  the 2,000,000 premine is NOT in these figures: five genesis")
    print("  outputs behind time locks, with no standard address to tally.")
    # And the total below is NOT the amount mined, which is the mistake this
    # line nearly shipped with. Every receipt is counted, so a coin that went
    # to a pool and then to a miner is counted twice -- which is why the
    # figure is about double the issuance. The "excluding pass-throughs" view
    # is the one that sums to roughly what has been mined.
    mined = 50 * d["height"]
    print(f"  {total / COIN:,.0f} WAM counted in receipts, against "
          f"{mined:,.0f} WAM actually mined:")
    print("  a coin paid to a pool and then to a miner is counted twice. The")
    print("  second table, without pass-throughs, is the one that sums to the")
    print("  issuance.\n")

    def show(title, rows, denom):
        print(f"  {BLD}{title}{OFF}")
        for addr, v in rows[:a.top]:
            short = addr if len(addr) <= 16 else f"{addr[:10]}...{addr[-4:]}"
            mark = " (pool)" if addr in pools else ""
            print(f"    {short:<20} {v / COIN:12,.2f} WAM  {100 * v / denom:5.1f}%{mark}")
        print()

    show("every address, as received", ranked, total)
    if end:
        show("excluding pool pass-throughs -- where the coins actually landed",
             end, end_total)
        top_end = 100 * end[0][1] / end_total
        print(f"  {GRN}{len(end)} end address(es); the largest holds "
              f"{top_end:.1f}% of what reached them{OFF}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

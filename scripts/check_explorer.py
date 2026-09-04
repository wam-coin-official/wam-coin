#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_explorer.py -- is the explorer telling the public the truth?
# ===========================================================================
#
#      python3 scripts/check_explorer.py --node HOST [--url URL]
#
#  WHY THIS EXISTS
#
#  The explorer is where a stranger goes to check us. It is the one place
#  that answers "is the 5% treasury real", "how much has been mined", "is
#  the premine actually locked" without their having to build anything. A
#  node that is wrong is a bug; an explorer that is wrong is a bug that
#  everyone reads and believes.
#
#  Nothing checked it. On 2026-08-21 the Electrum server had been dead for
#  39 hours and sweep.sh reported 14 passed, because every check asked about
#  the node, the consensus rules, the release or the deployed binaries --
#  and none asked whether the services people actually touch were answering,
#  let alone whether they were answering correctly.
#
#  TWO DIFFERENT QUESTIONS
#
#  Is it up, and is it right. The second is the one worth having:
#
#    up      it answers, its node is online, and its data is not stale.
#            A dashboard confidently displaying yesterday's chain is worse
#            than one that is plainly down, because nobody doubts it.
#
#    right   every economic number it publishes is compared against
#            src/wam/wam-params.h -- the file consensus is compiled from --
#            using the same parser verify_supply.py uses, so the two cannot
#            drift apart. If the explorer says the cap is 21,000,000 or the
#            treasury is 3%, that is caught here rather than by a reader.
#
#  The treasury address is checked against the burn placeholder specifically.
#  A mainnet explorer proudly reporting a treasury address of twenty zero
#  bytes means the ceremony never happened and the money goes nowhere.
# ===========================================================================

import argparse
import json
import os
import subprocess
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_supply import PARAMS_H, parse_params_header  # noqa: E402

# Addressing a chain with wam-cli lives in one place. Each of these files
# had its own copy, and every copy mapped mainnet to an EMPTY flag -- which
# means the default datadir, which on both servers is the TESTNET node. Asked
# to check mainnet, they all quietly checked testnet.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wamcli import flags as _wamcli_flags   # noqa: E402

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"
_fails = []


def ok(m):   print(f"  {GRN}ok{OFF}    {m}")
def bad(m):  print(f"  {RED}FAIL{OFF}  {m}"); _fails.append(m)
def warn(m): print(f"  {YEL}!!{OFF}    {m}")
def head(m): print(f"\n{BLD}{m}{OFF}")


def cmp(label, got, want, fmt=str):
    if got is None:
        bad(f"{label}: the explorer does not report it")
    elif got != want:
        bad(f"{label}: explorer says {fmt(got)}, wam-params.h says {fmt(want)}")
    else:
        ok(f"{label}: {fmt(got)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="https://explorer.wamcoin.org")
    ap.add_argument("--node", help="ssh host to read the true height from")
    ap.add_argument("--network", default="testnet",
                    choices=["mainnet", "testnet", "regtest"])
    ap.add_argument("--lag", type=int, default=5)
    ap.add_argument("--stale", type=int, default=300,
                    help="seconds of staleness before the data is not trustworthy")
    args = ap.parse_args()

    P = parse_params_header(PARAMS_H)
    COIN = P["WAM_COIN"]

    # --- is it up ---------------------------------------------------------
    head("the explorer answers")
    try:
        req = urllib.request.Request(args.url.rstrip("/") + "/api/status",
                                     headers={"User-Agent": "wam-check-explorer"})
        with urllib.request.urlopen(req, timeout=25) as r:
            d = json.load(r)
    except Exception as e:
        bad(f"{args.url} did not answer: {e}")
        print(f"\n  {RED}nothing else could be checked{OFF}\n")
        return 1
    ok(args.url)

    if not d.get("nodeOnline"):
        bad(f"the explorer is up but its node is not: {d.get('error')}")
    else:
        ok("its node is online")

    stale = d.get("staleSeconds")
    if stale is None:
        warn("the explorer does not report staleness")
    elif stale > args.stale:
        bad(f"its data is {stale}s old -- a dashboard showing an old chain "
            f"confidently is worse than one that is down")
    else:
        ok(f"data is {stale}s old")

    chain = d.get("chain") or {}
    supply = d.get("supply") or {}
    emission = d.get("emission") or {}
    treasury = d.get("treasury") or {}

    # --- does it see the chain the node sees ------------------------------
    head("it sees the same chain as the node")
    ok(f"explorer: chain={chain.get('name')} height={chain.get('blocks')}")
    if args.node:
        flag = _wamcli_flags(args.network)
        p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                            f"root@{args.node}", f"wam-cli {flag} getblockcount"],
                           capture_output=True, text=True, timeout=60)
        out = p.stdout.strip()
        if p.returncode == 0 and out.isdigit():
            lag = int(out) - (chain.get("blocks") or 0)
            if abs(lag) > args.lag:
                bad(f"explorer is {lag} blocks from the node ({out})")
            else:
                ok(f"node height {out}, explorer within {abs(lag)} block(s)")
        else:
            warn(f"could not read the node at {args.node}")

    if chain.get("pruned"):
        bad("the explorer's node is pruned -- it cannot answer about old blocks")
    if chain.get("syncing"):
        warn("the explorer's node reports it is still syncing")

    # --- are the numbers it publishes the consensus ones -------------------
    head("every number it publishes matches wam-params.h")
    w = lambda v: f"{v/COIN:,.0f} WAM"                                    # noqa: E731
    cmp("maximum supply",   supply.get("maxSupply"),        P["WAM_MAX_MONEY"], w)
    cmp("premine",          supply.get("premine"),          P["WAM_GENESIS_PREMINE"], w)
    cmp("mining allocation", supply.get("miningAllocation"), P["WAM_MINING_ALLOCATION"], w)
    cmp("halving interval", emission.get("halvingInterval"), P["WAM_SUBSIDY_HALVING_INTERVAL"],
        lambda v: f"{v:,} blocks")
    cmp("treasury percent", treasury.get("percent"),        P["WAM_DEVFEE_PERCENT"],
        lambda v: f"{v}%")
    cmp("treasury ends at", treasury.get("lastHeight"),     P["WAM_DEVFEE_LAST_HEIGHT"],
        lambda v: f"height {v:,}")
    cmp("block spacing",    chain.get("targetSpacing"),     P["WAM_POW_TARGET_SPACING"],
        lambda v: f"{v}s")

    sub = emission.get("subsidy")
    mine = emission.get("minerSubsidy")
    tre = emission.get("treasurySubsidy")
    if None in (sub, mine, tre):
        bad("the explorer does not publish the subsidy split")
    elif mine + tre != sub:
        bad(f"subsidy split does not add up: {mine} + {tre} != {sub}")
    else:
        ok(f"subsidy split: {mine/COIN:.8f} + {tre/COIN:.8f} = {sub/COIN:.8f} WAM")

    circ = supply.get("circulating")
    if circ is not None and supply.get("maxSupply"):
        if circ > supply["maxSupply"]:
            bad(f"circulating {circ/COIN:,.0f} exceeds the cap {supply['maxSupply']/COIN:,.0f}")
        else:
            ok(f"circulating {circ/COIN:,.2f} WAM "
               f"({supply.get('percentMined', 0):.2f}% of the cap)")

    # --- the placeholder that must never reach mainnet --------------------
    head("the treasury address is a real one")
    script = (treasury.get("script") or "").lower()
    addr = treasury.get("address")
    if not addr:
        bad("the explorer publishes no treasury address")
    elif "0000000000000000000000000000000000000000" in script:
        bad(f"the treasury pays to twenty zero bytes -- the burn placeholder. "
            f"On mainnet this means the ceremony never happened and 5% of every "
            f"block goes nowhere. (address shown: {addr})")
    else:
        ok(f"{addr}")
        # The treasury rule starts at height 1 (WAM_DEVFEE_START_HEIGHT), so on
        # a chain that is still at genesis it has correctly not begun. Saying
        # so as a finding was wrong twice over: the explorer was telling the
        # truth, and this counted the warning towards the failure total, so a
        # rehearsal against a height-0 mainnet node reported "1 check(s)
        # failed" about a chain where every number was right.
        #
        # Above height 0 an inactive treasury is a real fault and stays one:
        # it means 5% of every block is not reaching the address consensus
        # says it must.
        height = chain.get("blocks")
        if treasury.get("active") is False:
            if height == 0:
                ok("the treasury rule has not started yet -- it begins at "
                   "height 1, and this chain is at genesis")
            else:
                bad(f"the treasury rule reads as INACTIVE at height {height}, "
                    f"and it must be active from height 1. Five per cent of "
                    f"every block is not reaching {addr}.")

    # --- vesting ----------------------------------------------------------
    v = supply.get("vesting") or {}
    if v:
        head("the premine is locked")
        total, unlocked, locked = v.get("total"), v.get("unlocked"), v.get("locked")
        if None in (total, unlocked, locked):
            bad("the explorer publishes an incomplete vesting breakdown")
        elif unlocked + locked != total:
            bad(f"vesting does not add up: {unlocked} + {locked} != {total}")
        elif total != P["WAM_GENESIS_PREMINE"]:
            bad(f"vesting total {total/COIN:,.0f} != premine "
                f"{P['WAM_GENESIS_PREMINE']/COIN:,.0f}")
        else:
            ok(f"{locked/COIN:,.0f} WAM locked, {unlocked/COIN:,.0f} unlocked, "
               f"{len(v.get('schedule') or [])} tranche(s)")

    print()
    if _fails:
        print(f"  {RED}{len(_fails)} check(s) failed{OFF}")
        print("  This is where a stranger goes to check us. A number that is wrong\n"
              "  here is a number everyone reads and believes.\n")
        return 1
    print(f"  {GRN}the explorer publishes what consensus enforces{OFF}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

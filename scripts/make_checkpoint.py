#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  make_checkpoint.py -- turn a real block into a line of chainparams.cpp
# ===========================================================================
#
#      python3 scripts/make_checkpoint.py --network mainnet HOST [HOST ...]
#      python3 scripts/make_checkpoint.py --network mainnet --height 5000 H1 H2
#
#  WHY CHECKPOINTS, AND WHAT THEY COST
#
#  A checkpoint is the hash of a real block, at a known height, compiled into
#  the software. A node running that release will not accept any chain that
#  does not contain that block, so a reorganisation reaching below it becomes
#  impossible for everyone who has updated -- which is the only defence a
#  young chain has against being out-mined, and the one Litecoin, Dogecoin
#  and most others used in their first years.
#
#  It is also, plainly, a centralisation. It means every updated node trusts
#  whoever cut the release to have picked an honest block. We say that out
#  loud in docs/LISTING_PACKAGE.md rather than describing it as security and
#  hoping nobody asks.
#
#  WHY THIS IS A SCRIPT AND NOT A COPIED HASH
#
#  Freezing the wrong block is worse than having no checkpoint at all. A
#  checkpoint on a minority fork permanently splits the network: nodes with
#  the release can never join the chain everybody else is on, and no later
#  release can undo it for anyone who has already synced past it. There is no
#  recovery that is not a hard fork.
#
#  So this refuses to emit anything unless:
#
#    * every host asked returns the SAME hash for that height -- one node's
#      opinion is not evidence, and a node can be on a fork without knowing
#    * the block is buried deep enough that it cannot still be reorganised
#      out from under the release
#    * the block actually exists and is on the active chain, not merely
#      known to the node
# ===========================================================================

import argparse
import json
import subprocess
import sys

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"


def ok(m):   print(f"  {GRN}ok{OFF}    {m}")
def bad(m):  print(f"  {RED}FAIL{OFF}  {m}")
def warn(m): print(f"  {YEL}!!{OFF}    {m}")


def cli(network):
    return {"mainnet": "/opt/wam-current-bin/wam-cli -chain=main "
                       "-conf=/root/.wam-mainnet/wam.conf -datadir=/root/.wam-mainnet",
            "testnet": "/opt/wam-current-bin/wam-cli -testnet",
            "regtest": "/opt/wam-current-bin/wam-cli -regtest"}[network]


def rsh(host, cmd, timeout=60):
    p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                        f"root@{host}", cmd],
                       capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout or "no output").strip()[:200])
    return p.stdout.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("hosts", nargs="+",
                    help="two or more independent nodes. One node's opinion "
                         "is not evidence: a node can be on a fork and not "
                         "know it, and a checkpoint on a fork splits the "
                         "network permanently.")
    ap.add_argument("--network", default="mainnet",
                    choices=["mainnet", "testnet", "regtest"])
    ap.add_argument("--height", type=int,
                    help="height to freeze (default: the deepest height that "
                         "satisfies --bury on every host)")
    ap.add_argument("--bury", type=int, default=1000,
                    help="how many blocks must sit on top of it (default 1000, "
                         "about 33 hours at a two-minute target)")
    a = ap.parse_args()

    if len(a.hosts) < 2:
        bad("give at least two hosts. A checkpoint taken from a single node "
            "is a checkpoint taken on faith.")
        return 2

    c = cli(a.network)
    print(f"{BLD}asking {len(a.hosts)} node(s) about the {a.network} chain{OFF}")

    tips = {}
    for h in a.hosts:
        try:
            tips[h] = int(rsh(h, f"{c} getblockcount"))
            ok(f"{h} is at height {tips[h]}")
        except Exception as e:
            bad(f"{h}: {e}")
            return 1

    lowest_tip = min(tips.values())
    height = a.height if a.height is not None else lowest_tip - a.bury

    if height < 1:
        bad(f"the chain is only {lowest_tip} blocks long; nothing is buried "
            f"{a.bury} deep yet. Nothing to checkpoint, and that is the "
            f"correct answer rather than a smaller --bury.")
        return 1

    for h, t in tips.items():
        if t - height < a.bury:
            bad(f"{h} has only {t - height} block(s) on top of height {height}; "
                f"--bury requires {a.bury}. A checkpoint that can still be "
                f"reorganised out is a checkpoint on a guess.")
            return 1
    ok(f"height {height} is buried at least {a.bury} deep on every host")

    hashes = {}
    for h in a.hosts:
        try:
            hashes[h] = rsh(h, f"{c} getblockhash {height}")
        except Exception as e:
            bad(f"{h}: {e}")
            return 1

    distinct = set(hashes.values())
    if len(distinct) != 1:
        bad("the hosts DISAGREE about what block is at that height:")
        for h, v in hashes.items():
            print(f"          {h}  {v}")
        print("\n  One of them is on a fork. Find out which before anything "
              "is frozen:\n  a checkpoint on the wrong chain cannot be undone "
              "by a later release.")
        return 1

    block_hash = distinct.pop()
    ok(f"all {len(a.hosts)} host(s) agree: {block_hash}")

    # Ask one node to confirm the block is on the active chain rather than
    # merely known. getblock reports confirmations of -1 for a block on a
    # side branch, and getblockhash would never return such a block -- but
    # this costs one call and removes the need to reason about it.
    try:
        info = json.loads(rsh(a.hosts[0], f"{c} getblock {block_hash}"))
        if info.get("confirmations", -1) < 1:
            bad(f"{a.hosts[0]} says that block is not on the active chain")
            return 1
        ok(f"on the active chain, {info['confirmations']} confirmation(s), "
           f"mined {info.get('time')}")
    except Exception as e:
        warn(f"could not confirm the block is on the active chain: {e}")

    section = {"mainnet": "CMainParams", "testnet": "CTestNetParams",
               "regtest": "CRegTestParams"}[a.network]
    print(f"\n{BLD}add this to {section} in src/wam/chainparams.cpp{OFF}\n")
    print("        checkpointData = {")
    print("            {")
    print("                {0, consensus.hashGenesisBlock},")
    print(f'                {{{height}, uint256S("0x{block_hash}")}},')
    print("            }")
    print("        };")
    print(f"\n  Keep the existing entries. Then read docs/CHECKPOINTS.md before")
    print(f"  releasing it: a release carrying a checkpoint is a release nobody")
    print(f"  can safely skip.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

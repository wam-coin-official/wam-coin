#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_peer_versions.py -- who on this network will be left behind?
# ===========================================================================
#
#      python3 scripts/check_peer_versions.py --node HOST [--network testnet]
#
#  WHY THIS EXISTS
#
#  v0.1.5 changed the mainnet treasury address, which is a consensus rule. A
#  node still on v0.1.4 when mainnet opens will reject every valid block and
#  fork itself off at height 1.
#
#  Its operator is not left completely blind -- Core raises
#  LARGE_WORK_INVALID_CHAIN once the rejected chain is about six blocks of
#  work ahead, roughly twelve minutes in at this chain's spacing, and says
#  "We do not appear to fully agree with our peers". But that warning lives
#  in the log and in getnetworkinfo, our release ships without a GUI, and
#  nobody watches a node that has been quietly working for a week.
#
#  There is no way to message a peer. The protocol carries blocks and
#  transactions, not notices. What is possible is to KNOW: to see, before
#  launch day rather than after it, how many independent operators are still
#  on a version that will be rejected, so the announcement can be repeated
#  while it can still do some good.
#
#  WHAT IT DOES NOT DO
#
#  It does not print addresses. Running a node is a favour to this project,
#  and a list of who does it is a list of who to attack. Counts and versions
#  only, and country only where the operator's own node already announces it
#  in public DNS -- which is to say, our own seeds.
# ===========================================================================

import argparse
import json
import pathlib
import re
import subprocess
import sys
from collections import Counter

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from consensus_floor import floor as consensus_floor  # noqa: E402

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"
_fails = []


def ok(m):   print(f"  {GRN}ok{OFF}    {m}")
def bad(m):  print(f"  {RED}FAIL{OFF}  {m}"); _fails.append(m)
def warn(m): print(f"  {YEL}!!{OFF}    {m}")


def rsh(host, cmd, timeout=60):
    p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                        f"root@{host}", cmd],
                       capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout


def ver_tuple(s):
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", s or "")
    return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--node", default="pool.wamcoin.org")
    ap.add_argument("--network", default="testnet",
                    choices=["mainnet", "testnet", "regtest"])
    ap.add_argument("--ours", default="169.58.159.165,5.223.52.200,41.254.76.34",
                    help="addresses we run ourselves, excluded from the count of "
                         "independent operators")
    ap.add_argument("--window-hours", type=int, default=48,
                    help="also count anyone who introduced themselves within "
                         "this many hours, not only whoever is connected at "
                         "the instant this runs. An intermittent node is "
                         "absent most of the time and present when it "
                         "matters. 0 disables it.")
    args = ap.parse_args()

    flag = {"mainnet": "", "testnet": "-testnet", "regtest": "-regtest"}[args.network]
    ours = {a.strip() for a in args.ours.split(",") if a.strip()}

    print(f"\n{BLD}who is on this network, and on what{OFF}")

    rc, out = rsh(args.node, f"wam-cli {flag} getpeerinfo")
    if rc != 0 or not out.strip():
        bad(f"could not read the peer list from {args.node}")
        print()
        return 1
    try:
        peers = json.loads(out)
    except Exception as e:
        bad(f"peer list is not JSON: {e}")
        print()
        return 1

    rc, mine = rsh(args.node, f"wam-cli {flag} getnetworkinfo")
    current = "0.0.0"
    if rc == 0:
        m = re.search(r'"subversion"\s*:\s*"/WAM:([0-9.]+)/"', mine)
        if m:
            current = m.group(1)
    ok(f"this node runs v{current}")

    # One operator can hold several connections. Counting connections instead
    # of addresses turns two sockets from one machine into two operators, and
    # the number that matters is how many PEOPLE need to act.
    by_addr = {}
    for p in peers:
        ip = p.get("addr", "").rsplit(":", 1)[0].strip("[]")
        v = re.search(r"/WAM:([0-9.]+)/", p.get("subver", "") or "")
        by_addr[ip] = v.group(1) if v else "unknown"

    # Peers seen recently, not only peers connected at this instant.
    #
    # On 2026-08-30 this check went green because the one operator on an
    # outdated version happened to be offline when it ran. He had completed a
    # version handshake three and a half hours earlier and was gone again.
    # Run at 19:05 the answer was red; run at 19:40 it was green; the network
    # had not changed at all.
    #
    # A check whose answer depends on the minute it was run is not a check,
    # and this is the one warning that has to be believed on 15 September. So
    # the journal is read too: anyone who introduced themselves inside the
    # window counts, whether or not they are here right now.
    seen = {}
    if args.window_hours > 0:
        rc, log = rsh(args.node,
                      f"journalctl -u wamd --since '-{args.window_hours}h' "
                      f"--no-pager -o cat 2>/dev/null | "
                      f"grep -E 'receive version message: /WAM:'", timeout=90)
        for line in (log or "").splitlines():
            m = re.search(r"/WAM:([0-9.]+)/", line)
            t = re.match(r"(\S+)", line)
            if m:
                seen.setdefault(m.group(1), []).append(t.group(1) if t else "?")
        if seen:
            for v in sorted(seen, key=ver_tuple):
                ok(f"seen in the last {args.window_hours}h: v{v} "
                   f"({len(seen[v])} handshake(s), last {seen[v][-1]})")
        else:
            warn(f"the journal shows no version handshakes in {args.window_hours}h "
                 f"-- net logging may be off, so this window proves nothing")

    if not by_addr:
        bad("no peers at all -- this node is alone, which proves nothing about "
            "the network but says a great deal about this node")
        print()
        return 1

    # The line that matters is not "older than what we happen to run". It is
    # "older than the release that last changed a consensus rule", and that is
    # derived from the repository rather than from whichever node was asked.
    #
    # Getting this wrong is not a cosmetic error. Within an hour of upgrading
    # our own nodes to v0.1.6 -- a miner fix touching no rule -- this check
    # was reporting that a node on v0.1.5 would be thrown off mainnet at
    # height 1. An operator who had just done exactly the right thing would
    # have been told it was not enough, by the one warning here that has to be
    # believed on 15 September.
    floor_tag, floor_why = consensus_floor()
    floor_v = (floor_tag or "0.0.0").lstrip("v")
    ok(f"consensus floor: v{floor_v} -- {floor_why}")

    counts = Counter(by_addr.values())
    print()
    for v in sorted(counts, key=ver_tuple, reverse=True):
        if ver_tuple(v) < ver_tuple(floor_v):
            marker = "   <- will be rejected on mainnet"
        elif ver_tuple(v) < ver_tuple(current):
            marker = "   (older than ours, and valid)"
        else:
            marker = ""
        print(f"        v{v:<10} {counts[v]} peer(s){marker}")

    independent = {ip: v for ip, v in by_addr.items() if ip not in ours}
    behind = {ip: v for ip, v in independent.items()
              if ver_tuple(v) < ver_tuple(floor_v)}
    older = {ip: v for ip, v in independent.items()
             if ver_tuple(floor_v) <= ver_tuple(v) < ver_tuple(current)}

    print()
    ok(f"{len(by_addr)} peer(s), of which {len(independent)} are not ours")

    if not independent:
        warn("no independent node is connected -- there is nobody to warn, and "
             "nobody to notice if this chain stops")
    elif behind:
        bad(f"{len(behind)} of {len(independent)} independent operator(s) run a "
            f"version older than v{floor_v}, the release that last changed a "
            f"consensus rule. On mainnet each of them will reject every valid "
            f"block and fork off at height 1. They cannot be messaged -- the "
            f"protocol carries no notices -- so the announcement channels and "
            f"the GitHub release watch are the only ways they will hear.")
        for v in sorted(set(behind.values()), key=ver_tuple):
            print(f"        {sum(1 for x in behind.values() if x == v)} on v{v}")
    else:
        # Nobody connected right now is behind. That is not the same as
        # nobody being behind: an intermittent node is absent most of the
        # time and present when it matters. The window is what decides.
        stale_seen = {v: t for v, t in seen.items()
                      if ver_tuple(v) < ver_tuple(floor_v)}
        if stale_seen:
            for v, times in sorted(stale_seen.items(), key=lambda kv: ver_tuple(kv[0])):
                bad(f"nobody on v{v} is connected at this moment, but one "
                    f"introduced itself {len(times)} time(s) in the last "
                    f"{args.window_hours}h -- last at {times[-1]}. It is "
                    f"intermittent, not gone, and on 15 September it will "
                    f"fork off whenever it next appears.")
        else:
            ok(f"every independent operator is on v{floor_v} or newer -- none "
               f"of them will be rejected")
            if args.window_hours > 0 and seen:
                ok(f"and nothing older introduced itself in the last "
                   f"{args.window_hours}h either")
        # Said, but not as a failure. Running one release behind is a choice
        # an operator is entitled to make, and calling it red teaches them to
        # stop reading the colour.
        if older:
            warn(f"{len(older)} of them run something older than the v{current} "
                 f"we run, which is valid and costs them only whatever that "
                 f"release fixed")

    print()
    if _fails:
        print(f"  {RED}someone on this network will be left behind{OFF}\n")
        return 1
    print(f"  {GRN}nobody on this network is on a version that will be rejected{OFF}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

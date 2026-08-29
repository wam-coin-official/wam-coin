#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_reorg.py -- did a block that was confirmed stop being confirmed?
# ===========================================================================
#
#      python3 scripts/check_reorg.py --network testnet HOST [HOST ...]
#      python3 scripts/check_reorg.py --local --network mainnet
#      python3 scripts/check_reorg.py --local --depth 3 --announce
#
#  WHY THIS EXISTS
#
#  A new proof-of-work chain is cheap to reorganise, and WAM is a RandomX
#  chain, which means the hardware that attacks it is CPU -- the most
#  rentable resource there is. Monero is safe because its hashrate is
#  enormous. A chain in its first weeks is not Monero.
#
#  What that attack actually does is narrow, and worth stating precisely
#  because the fear is usually aimed at the wrong thing: it does not touch
#  anybody's wallet and it cannot move coins the attacker does not own. It
#  lets the attacker spend their own coins twice -- deposit somewhere, take
#  the value out, then publish a longer chain in which the deposit never
#  happened. The victim is whoever accepted the payment on few
#  confirmations. Almost always an exchange.
#
#  There is no way to make that impossible for a young chain. There is a way
#  to not be the last to know. A reorganisation is visible from any node the
#  moment it lands, and the difference between hearing about it in four
#  minutes and hearing about it in four days is the difference between one
#  exchange losing one deposit and every exchange delisting.
#
#  So this asks two questions, and they catch different things:
#
#    1. Is there a competing branch, and how deep?  getchaintips shows
#       branches the node knows about but has not switched to. An attacker
#       who mined in private and then published shows up here at full depth
#       BEFORE the node reorganises onto it, if we are quick. This is the
#       early warning.
#
#    2. Has a hash we recorded at a given height changed?  This is the
#       proof. A branch can be pruned and forgotten; a block that used to be
#       at height 3,600 and is not there any more cannot be explained away.
#       Nothing else in our checks would notice it.
#
#  CALIBRATION, MEASURED RATHER THAN GUESSED
#
#  On 2026-08-29, with 3,608 blocks of testnet behind us, the deepest side
#  branch the node had ever held was ONE block, and there were three of
#  them, all valid-headers -- headers received for blocks we never fetched.
#  That is ordinary and happens on every chain.
#
#  So depth 1 is noise. The default alarm is 2, which on this chain's own
#  history has never happened. An alarm that fires weekly is an alarm nobody
#  reads, and an alarm that has never fired is one people believe.
# ===========================================================================

import argparse
import json
import os
import subprocess
import sys
import time

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"

_fails = []
_warns = []


def ok(m):   print(f"  {GRN}ok{OFF}    {m}")
def bad(m):  print(f"  {RED}FAIL{OFF}  {m}"); _fails.append(m)
def warn(m): print(f"  {YEL}!!{OFF}    {m}"); _warns.append(m)


# Heights are remembered sparsely rather than every one of them. A reorg
# deep enough to matter crosses several of these no matter where it starts,
# and twenty numbers is one round trip instead of five hundred.
OFFSETS = [1, 2, 3, 4, 5, 6, 8, 10, 15, 20, 30, 50, 75, 100, 150, 200, 300, 500, 1000]

# Anything older than this is dropped. A reorg five thousand blocks deep is
# not something a watcher tells you about; it is something you read in the
# news.
FORGET_AFTER = 5000


def run(host, cmd, timeout=60):
    """Run a shell command locally or on a host, and return its stdout."""
    if host in (None, "", "local", "localhost"):
        argv = ["bash", "-lc", cmd]
    else:
        argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                f"root@{host}", cmd]
    p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout or "no output").strip()[:300])
    return p.stdout


def cli(network, datadir=None):
    flag = {"mainnet": "-chain=main -conf=/root/.wam-mainnet/wam.conf "
                       "-datadir=/root/.wam-mainnet",
            "testnet": "-testnet",
            "regtest": "-regtest"}[network]
    # --datadir overrides the lot. It exists so this can be proved against a
    # throwaway regtest chain where a reorganisation can actually be caused
    # on purpose, without going anywhere near a node that matters.
    if datadir:
        flag = {"mainnet": "-chain=main", "testnet": "-testnet",
                "regtest": "-regtest"}[network] + f" -datadir={datadir}"
    return f"/opt/wam-current-bin/wam-cli {flag}"


def state_path(directory, host, network):
    tag = (host or "local").replace("/", "_").replace(":", "_")
    return os.path.join(directory, f"reorg-{network}-{tag}.json")


def load_state(path):
    try:
        with open(path) as f:
            d = json.load(f)
        return {int(k): v for k, v in d.get("heights", {}).items()}, d
    except (OSError, ValueError):
        return {}, {}


def save_state(path, heights, tip):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"heights": {str(k): v for k, v in heights.items()},
                   "tip": tip, "written": int(time.time())}, f, indent=1)
    os.replace(tmp, path)          # never leave a half-written state file


def raise_alarm(state_dir, network, host, detail):
    """Leave evidence that outlives the run that found it.

    A reorganisation is over in minutes. If this only reported through its
    exit status, the run two minutes later would find a perfectly consistent
    chain, say ok, and the one event anybody needed to know about would be a
    line in a journal that rotates. So it is written to a file, and the file
    stays until a person deletes it -- the same reason the backup check
    trusts a file on disk over a service that reported success.
    """
    os.makedirs(state_dir, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    p = os.path.join(state_dir, f"ALARM-{network}-{stamp}.json")
    with open(p, "w") as f:
        json.dump({"utc": stamp, "network": network,
                   "host": host or "local", "detail": detail}, f, indent=1)
    return p


def outstanding_alarms(state_dir):
    try:
        return sorted(f for f in os.listdir(state_dir) if f.startswith("ALARM-"))
    except OSError:
        return []


def check(host, network, depth_alarm, state_dir, datadir=None):
    label = host or "this machine"
    print(f"\n{BLD}{label} -- {network}{OFF}")
    c = cli(network, datadir)

    # ---- one round trip for everything the check needs -------------------
    try:
        raw = run(host, f"{c} getblockcount && echo --- && {c} getchaintips")
    except Exception as e:
        bad(f"{label}: node not answering ({e})")
        return
    try:
        head, tips_raw = raw.split("---", 1)
        tip = int(head.strip())
        tips = json.loads(tips_raw)
    except (ValueError, json.JSONDecodeError) as e:
        bad(f"{label}: could not read the node's reply ({e})")
        return

    # ---- 1. competing branches ------------------------------------------
    # An "active" tip is our own chain. Everything else is a branch the node
    # has heard of. valid-fork means we have the full blocks and they are
    # valid -- one more block of work on that side and we switch to it.
    worst = 0
    for t in tips:
        if t.get("status") == "active":
            continue
        d = int(t.get("branchlen", 0))
        worst = max(worst, d)
        if d >= depth_alarm:
            fn = bad if t.get("status") == "valid-fork" else warn
            fn(f"{label}: a competing branch {d} blocks deep at height "
               f"{t['height']} ({t.get('status')}) -- {t['hash'][:16]}...")

    if worst < depth_alarm:
        ok(f"deepest competing branch is {worst} block(s); alarm is at {depth_alarm}")

    # ---- 2. did a hash we recorded change? ------------------------------
    path = state_path(state_dir, host, network)
    known, prev = load_state(path)
    prev_tip = prev.get("tip")

    wanted = sorted({tip - o for o in OFFSETS if tip - o >= 0}
                    | {h for h in known if h <= tip and h > tip - FORGET_AFTER})
    if not wanted:
        ok("chain too short to have anything to compare yet")
        save_state(path, {}, tip)
        return

    # One command, one round trip, one line per height.
    script = "; ".join(f'echo "{h} $({c} getblockhash {h} 2>/dev/null)"' for h in wanted)
    try:
        out = run(host, script, timeout=120)
    except Exception as e:
        bad(f"{label}: could not read block hashes ({e})")
        return

    now = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and len(parts[1]) == 64:
            now[int(parts[0])] = parts[1]

    changed = [(h, known[h], now[h]) for h in sorted(known)
               if h in now and known[h] != now[h]]

    if changed:
        # Depth is measured against the tip we last recorded, not the tip
        # now. Everything above the old tip is honest new work: counting it
        # as "rewritten" inflates the number, and this is a number that gets
        # quoted to an exchange deciding whether its deposits are safe.
        shallowest = min(h for h, _, _ in changed)
        depth = (prev_tip - shallowest + 1) if prev_tip else len(changed)
        msg = (f"{label}: REORGANISATION {depth} block(s) deep -- the chain was "
               f"rewritten from height {shallowest}. {len(changed)} recorded "
               f"height(s) no longer hold the block they held. Tip is now {tip}"
               + (f", was {prev_tip}." if prev_tip else "."))
        bad(msg)
        try:
            p = raise_alarm(state_dir, network, host,
                            {"message": msg, "depth": depth,
                             "from_height": shallowest, "tip": tip,
                             "previous_tip": prev_tip,
                             "changed": [{"height": h, "was": w, "now": n}
                                         for h, w, n in changed]})
            print(f"          evidence written to {p}")
            print(f"          it stays until a person deletes it")
        except OSError as e:
            warn(f"could not write the alarm file: {e}")
        for h, was, isnow in changed[:6]:
            print(f"          height {h}")
            print(f"            was  {was}")
            print(f"            now  {isnow}")
        if len(changed) > 6:
            print(f"          ... and {len(changed) - 6} more")
    else:
        if known:
            ok(f"{len(known)} recorded height(s) still hold the same blocks")
        else:
            ok(f"first run -- recorded {len(now)} height(s) to compare against")

    # Merge rather than replace: a height we recorded last week is a better
    # tripwire than one recorded a minute ago.
    merged = {h: v for h, v in known.items() if h > tip - FORGET_AFTER}
    merged.update(now)
    save_state(path, merged, tip)


def announce(text, repo):
    """Publish the alarm. Deliberate, never automatic -- see main()."""
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write(text)
        p = f.name
    try:
        subprocess.run(["node", os.path.join(repo, "bots", "say.js"),
                        "--file", p], check=True, timeout=120)
    finally:
        os.unlink(p)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("hosts", nargs="*", help="hosts to ask; omit with --local")
    ap.add_argument("--local", action="store_true",
                    help="ask this machine's own node instead of an ssh host")
    ap.add_argument("--network", default="testnet",
                    choices=["mainnet", "testnet", "regtest"])
    ap.add_argument("--depth", type=int, default=2,
                    help="alarm at a competing branch this deep (default 2; "
                         "the deepest ever seen on this chain is 1)")
    ap.add_argument("--state-dir", default="/var/lib/wam-reorg",
                    help="where the recorded heights are kept")
    ap.add_argument("--datadir",
                    help="override the node data directory. Exists so this can "
                         "be proved against a throwaway regtest chain, where a "
                         "reorganisation can be caused on purpose.")
    ap.add_argument("--announce", action="store_true",
                    help="publish the alarm to the channels. Off by default: "
                         "a false alarm published is worse than a real one "
                         "found late, and this is a decision a person makes.")
    a = ap.parse_args()

    targets = a.hosts if a.hosts else ([None] if a.local else [])
    if not targets:
        ap.error("give one or more hosts, or --local")

    print(f"{BLD}has any confirmed block stopped being confirmed?{OFF}")

    # Anything found on an earlier run is still a finding. A run that says ok
    # two minutes after a reorganisation is telling the truth about the
    # chain now and nothing at all about what happened.
    old = outstanding_alarms(a.state_dir)
    for f in old:
        bad(f"an earlier run recorded a reorganisation: {a.state_dir}/{f}")
    if old:
        print(f"  {YEL}      delete those files once each one has been "
              f"looked at and understood{OFF}")

    for h in targets:
        try:
            check(h, a.network, a.depth, a.state_dir, a.datadir)
        except Exception as e:                      # never let one host hide another
            bad(f"{h or 'this machine'}: {type(e).__name__}: {e}")

    print()
    if _fails:
        print(f"  {RED}{len(_fails)} finding(s) that need a person{OFF}")
        if a.announce:
            announce("Chain reorganisation detected on WAM " + a.network +
                     ".\n\n" + "\n".join(_fails) +
                     "\n\nExchanges and pools: raise your confirmation "
                     "requirement until this is explained.",
                     os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        return 1
    if _warns:
        print(f"  {YEL}{len(_warns)} thing(s) worth a look, nothing confirmed{OFF}")
        return 0
    print(f"  {GRN}nothing rewritten{OFF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

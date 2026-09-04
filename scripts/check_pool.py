#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_pool.py -- does the pool give miners work, and does it pay them?
# ===========================================================================
#
#      python3 scripts/check_pool.py --node HOST [--api URL] [--stratum HOST]
#
#  WHY THIS EXISTS
#
#  On 2026-08-21 this pool had found 150 blocks, owed 16,176 WAM to two
#  miners, and had paid exactly nothing since the chain started. Every ten
#  minutes since genesis its payout had failed with "Fee estimation failed.
#  Fallbackfee is disabled", and nothing anywhere said so. The pool page was
#  green, the service was active, the stratum ports were open, miners were
#  connected and submitting shares, and blocks were being found.
#
#  It was discovered by a human opening the pool's own web page while doing
#  something unrelated. sweep.sh had been run that morning and reported
#  14 passed.
#
#  A pool that accepts work and never pays is worse than a pool that is down.
#  A miner notices a pool that is down in seconds; this one takes days to
#  notice, and by then the electricity is spent.
#
#  WHAT IS CHECKED, AND WHY EACH ONE
#
#    the API answers               a pool nobody can query is a pool nobody
#                                  can audit
#    it sees the same chain        pool height against the node's, so a pool
#                                  stuck on a fork is not reported healthy
#    the subsidy split is the      minerSubsidy + treasurySubsidy must equal
#    consensus one                 blockSubsidy, and the treasury share must
#                                  be what the consensus rule enforces. A
#                                  pool that disagrees with the chain about
#                                  the money is paying from a number it
#                                  invented.
#    every stratum port issues     not "is the port open" -- it subscribes,
#    real work                     authorises, and waits for a mining.notify.
#                                  A port that accepts connections and never
#                                  sends a job is a port where miners burn
#                                  electricity for nothing.
#    the RandomX seed matches      the seed height the pool hands out must
#    the chain                     match the epoch the chain is in, or every
#                                  share computed against it is invalid
#    PAYOUTS ARE ALIVE             blocks matured and nobody paid is a
#                                  failure. Owed above the payout threshold
#                                  with payments stopped is a failure. This
#                                  is the check that was missing.
#
#  Exit 0 only if all of it holds. Nothing checked is a failure, not a pass.
# ===========================================================================

import os
import argparse
import json
import socket
import ssl
import subprocess
import sys
import time
import urllib.request

# Addressing a chain with wam-cli lives in one place. Each of these files
# had its own copy, and every copy mapped mainnet to an EMPTY flag -- which
# means the default datadir, which on both servers is the TESTNET node. Asked
# to check mainnet, they all quietly checked testnet.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wamcli import flags as _wamcli_flags   # noqa: E402

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"
COIN = 100_000_000

_fails = []


def ok(m):   print(f"  {GRN}ok{OFF}    {m}")
def bad(m):  print(f"  {RED}FAIL{OFF}  {m}"); _fails.append(m)
def warn(m): print(f"  {YEL}!!{OFF}    {m}")
def head(m): print(f"\n{BLD}{m}{OFF}")


def fetch(url, timeout=25):
    req = urllib.request.Request(url, headers={"User-Agent": "wam-check-pool"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def node_height(host, network):
    flag = _wamcli_flags(network)
    p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                        f"root@{host}", f"wam-cli {flag} getblockcount"],
                       capture_output=True, text=True, timeout=60)
    out = p.stdout.strip()
    return int(out) if p.returncode == 0 and out.isdigit() else None


# ---------------------------------------------------------------------------
def stratum_job(host, port, address, timeout=25, use_tls=False):
# ---------------------------------------------------------------------------
#  Subscribe, authorise, and wait for work. Returns (info, error).
#
#  Authorising creates nothing: only a submitted share credits anyone, and
#  this never submits. The address is therefore any well-formed one.
# ---------------------------------------------------------------------------
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        if use_tls:
            # An encrypted port answers a plain connection by closing it, and
            # the first version of this check reported that as "server closed
            # the connection" -- a failure message about a port that was
            # working perfectly, on the day it was added.
            s = ssl.create_default_context().wrap_socket(s, server_hostname=host)
    except ssl.SSLError as e:
        return None, f"TLS failed: {e}"
    except Exception as e:
        return None, f"{type(e).__name__}"

    info, buf, deadline = {}, b"", time.time() + timeout
    try:
        s.sendall((json.dumps({"id": 1, "method": "mining.subscribe",
                               "params": ["wam-check/1.0"]}) + "\n").encode())
        s.sendall((json.dumps({"id": 2, "method": "mining.authorize",
                               "params": [f"{address}.check", "x"]}) + "\n").encode())

        while time.time() < deadline and "job" not in info:
            s.settimeout(max(0.5, deadline - time.time()))
            try:
                chunk = s.recv(8192)
            except socket.timeout:
                break
            if not chunk:
                return None, "server closed the connection"
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    m = json.loads(line)
                except Exception:
                    continue
                if m.get("id") == 1 and m.get("result"):
                    info["extranonce1"] = m["result"][1]
                elif m.get("id") == 2:
                    info["authorized"] = m.get("result") is True
                elif m.get("method") == "mining.set_difficulty":
                    info["difficulty"] = (m.get("params") or [None])[0]
                elif m.get("method") == "mining.set_seedhash":
                    p = m.get("params") or []
                    info["seedhash"] = p[0] if p else None
                    info["seedheight"] = p[1] if len(p) > 1 else None
                elif m.get("method") == "mining.notify":
                    info["job"] = (m.get("params") or [None])[0]
        return info, None
    except Exception as e:
        return None, f"{type(e).__name__}: {e}"
    finally:
        try:
            s.close()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default="https://pool.wamcoin.org/api/stats")
    ap.add_argument("--stratum", default="pool.wamcoin.org")
    ap.add_argument("--node", help="ssh host to read the true height from")
    ap.add_argument("--network", default="testnet",
                    choices=["mainnet", "testnet", "regtest"])
    ap.add_argument("--address", default="twam1q0g97ezlr7j6apx9y4gva3rc99x5l5kjh6g66da",
                    help="a well-formed address to authorise with; nothing is submitted")
    ap.add_argument("--lag", type=int, default=5, help="blocks the pool may trail the node")
    ap.add_argument("--payout-interval", type=int, default=600,
                    help="seconds between payout runs, from the pool config")
    args = ap.parse_args()

    # --- the API ----------------------------------------------------------
    head("the pool answers")
    try:
        d = fetch(args.api)
    except Exception as e:
        bad(f"{args.api} did not answer: {e}")
        print(f"\n  {RED}nothing else could be checked{OFF}\n")
        return 1
    ok(f"{args.api}")

    pool, net, cfg = d.get("pool", {}), d.get("network", {}), d.get("config", {})
    if not pool or not net:
        bad("the API answered but has no pool/network section -- shape changed")
        return 1

    # --- same chain as the node -------------------------------------------
    head("the pool and the node see the same chain")
    ok(f"pool reports chain={net.get('chain')} height={net.get('blocks')}")
    if args.node:
        h = node_height(args.node, args.network)
        if h is None:
            warn(f"could not read the node at {args.node}; height unverified")
        else:
            lag = h - (net.get("blocks") or 0)
            if abs(lag) > args.lag:
                bad(f"pool is {lag} blocks from the node ({h}) -- it is building on "
                    f"something the chain does not agree with")
            else:
                ok(f"node height {h}, pool within {abs(lag)} block(s)")

    # --- the money the pool believes in -----------------------------------
    head("the subsidy split matches consensus")
    sub, mine, tre = net.get("blockSubsidy"), net.get("minerSubsidy"), net.get("treasurySubsidy")
    if None in (sub, mine, tre):
        bad("the API does not report the subsidy split")
    else:
        if mine + tre != sub:
            bad(f"minerSubsidy {mine} + treasurySubsidy {tre} != blockSubsidy {sub} -- "
                f"the pool is paying from a number that does not add up")
        else:
            ok(f"{mine/COIN:.8f} + {tre/COIN:.8f} = {sub/COIN:.8f} WAM")
        want = cfg.get("chainDevFeePercent")
        if want is not None and sub:
            actual = tre * 100.0 / sub
            if abs(actual - want) > 0.01:
                bad(f"treasury is {actual:.2f}% of the subsidy, pool config says {want}%")
            else:
                ok(f"treasury {actual:.2f}% of the subsidy, enforced by the coinbase")

    # --- every port actually hands out work -------------------------------
    head("every stratum port issues real work")
    ports = cfg.get("ports") or []
    if not ports:
        bad("the API lists no stratum ports -- nothing to check")
    for p in ports:
        port = p.get("port")
        is_tls = bool(p.get("tls"))
        info, err = stratum_job(args.stratum, port, args.address, use_tls=is_tls)
        label = f"{args.stratum}:{port}{' TLS' if is_tls else ''}"
        if err:
            bad(f"{label}  {err}")
            continue
        if not info.get("authorized"):
            bad(f"{label}  connected but mining.authorize did not return true")
            continue
        if not info.get("job"):
            bad(f"{label}  authorised but no mining.notify arrived -- a miner here "
                f"would burn electricity for nothing")
            continue
        bits = [f"job {info['job']}"]
        if info.get("difficulty") is not None:
            bits.append(f"diff {info['difficulty']}")
        # A seed from the wrong epoch makes every share computed against it
        # invalid, and the miner is told nothing.
        sh = info.get("seedheight")
        if sh is not None and net.get("blocks") is not None:
            if sh > net["blocks"]:
                bad(f"{label}  RandomX seed height {sh} is ahead of the chain "
                    f"({net['blocks']})")
                continue
            bits.append(f"seed@{sh}")
        ok(f"{label}  {', '.join(bits)}")

    # --- and the whole point: are miners actually paid --------------------
    head("miners are actually paid")
    confirmed = pool.get("blocksConfirmed", 0)
    paid = pool.get("totalPaid", 0)
    owed = pool.get("totalOwed", 0)
    payments = pool.get("recentPayments") or []
    minimum = (cfg.get("minimumPayoutWam") or 0) * COIN

    print(f"        blocks confirmed {confirmed}, pending {pool.get('blocksPending', 0)}, "
          f"orphaned {pool.get('blocksOrphaned', 0)}")
    print(f"        paid {paid/COIN:.8f} WAM, owed {owed/COIN:.8f} WAM, "
          f"{len(payments)} payment record(s)")

    if confirmed == 0:
        warn("no block has matured yet, so no payment is due -- this proves nothing "
             "about payouts")
    elif paid == 0:
        bad(f"{confirmed} block(s) matured and NOTHING has ever been paid. Miners are "
            f"owed {owed/COIN:.2f} WAM. This is the exact state the pool was in for "
            f"the whole life of the chain before v0.1.4.")
    else:
        ok(f"{paid/COIN:.2f} WAM paid out across {len(payments)} run(s)")

        # Owed above the threshold with payments stopped is the same failure
        # arriving more slowly.
        if payments:
            newest = max(p.get("time", 0) for p in payments) / 1000.0
            age = time.time() - newest
            if owed >= minimum > 0 and age > args.payout_interval * 3:
                bad(f"owed {owed/COIN:.2f} WAM is above the {minimum/COIN:g} WAM "
                    f"threshold and the last payment was {age/60:.0f} minutes ago "
                    f"(interval is {args.payout_interval//60} min) -- payouts have stopped")
            else:
                ok(f"last payment {age/60:.0f} minute(s) ago, owed {owed/COIN:.2f} WAM")
        elif owed >= minimum > 0:
            bad(f"owed {owed/COIN:.2f} WAM with no payment record at all")

    miners = pool.get("miners", 0)
    if miners == 0:
        warn("no miner is connected -- the pool is idle, which is a state, not a fault")
    else:
        ok(f"{miners} miner(s), {pool.get('workers', 0)} worker(s), "
           f"{pool.get('hashrate', 0):.0f} H/s")

    print()
    if _fails:
        print(f"  {RED}{len(_fails)} check(s) failed{OFF}")
        print("  A pool that takes work and does not pay is worse than one that is\n"
              "  down: a miner notices down in seconds and this in days.\n")
        return 1
    print(f"  {GRN}the pool gives work and pays for it{OFF}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

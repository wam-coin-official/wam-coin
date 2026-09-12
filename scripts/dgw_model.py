#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""dgw_model.py -- what DarkGravityWave does to a hash rate step, before one arrives.

    python3 scripts/dgw_model.py --validate            # against the real chain
    python3 scripts/dgw_model.py --simulate 20         # a 20x arrival and departure
    python3 scripts/dgw_model.py --validate --simulate 20

WHY THIS EXISTS

docs/ROADMAP.md section 2.7 says:

    Point 20x hashrate at it for an hour, then remove it
    proves DGWv3 absorbs and recovers

It is listed as a task and there is no record in docs/REHEARSALS.md that it
was ever run. On 12 September the founder asked which attacks a chain with no
value actually attracts, and the honest answer put this first: nobody has to
mean us harm. The network is one ordinary desktop's worth of hash rate and
RandomX rents by the hour, so somebody looking for a cheap coin points real
hardware at it, difficulty climbs, and then they leave -- and the difficulty
they caused stays behind. Blocks stop until the retarget catches up. That is
the likeliest event of launch week and it is the one thing on the list that
had never been measured.

We cannot buy 20x our own network to find out. What we can do is compute it.

WHY A MODEL IS ALLOWED TO ANSWER THIS

Because it is checked against the past first, and refused if it is wrong
about even one block.

This project has been bitten three times by one fact living in two places, so
a Python reimplementation of a consensus rule is exactly the shape of thing to
distrust. The answer is --validate: it walks the real chain and, for every
block from height 24 to the tip, computes what nBits that block should carry
from its 24 predecessors and compares it to the nBits the block actually
carries. Thousands of independent comparisons against a chain that was
produced by the C++. One mismatch and this file is wrong and says so.

Only then does --simulate use it, and what it produces is arithmetic about
DGW, not a claim about the network.

WHAT IS MIRRORED, EXACTLY

src/wam/pow.cpp, DarkGravityWave():

  * a 24-block window (WAM_DGW_PAST_BLOCKS)
  * the running mean avg_n = (avg_{n-1} * n + t_n) / (n + 1), avg_1 = t_1,
    walked from the newest block backwards -- deliberately NOT a plain mean:
    the (n+1) divisor weights recent blocks more heavily, which is where
    DGW's fast response comes from
  * actual timespan = time(newest) - time(oldest of the 24)
  * target timespan = 24 * 120 s = 2880 s
  * clamped to [target/3, target*3]
  * new target = avg * actual / target, capped at powLimit
  * integer division throughout, and the compact encoding's own truncation

The truncation matters. arith_uint256 divides as integers and GetCompact
throws away everything below the top three bytes of the mantissa, so a model
using floating point agrees with the chain approximately and is useless for
this.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request

PAST_BLOCKS = 24
TARGET_SPACING = 120
CLAMP = 3
TARGET_TIMESPAN = PAST_BLOCKS * TARGET_SPACING

# testnet powLimit. Read from the source rather than typed, below.
POW_LIMIT_DEFAULT = (1 << 232) - 1


# ---------------------------------------------------------------------------
#  The compact encoding, as arith_uint256 does it
# ---------------------------------------------------------------------------

def compact_to_target(nbits):
    """arith_uint256::SetCompact."""
    size = nbits >> 24
    word = nbits & 0x007FFFFF
    if size <= 3:
        return word >> (8 * (3 - size))
    return word << (8 * (size - 3))


def target_to_compact(target):
    """arith_uint256::GetCompact.

    The normalisation when the high bit of the mantissa is set is not
    cosmetic: without it the value would read as negative, and the result
    would not round-trip.
    """
    size = (target.bit_length() + 7) // 8
    if size <= 3:
        compact = target << (8 * (3 - size))
    else:
        compact = target >> (8 * (size - 3))
    if compact & 0x00800000:
        compact >>= 8
        size += 1
    return compact | (size << 24)


# ---------------------------------------------------------------------------
#  DarkGravityWave
# ---------------------------------------------------------------------------

def dgw(window, pow_limit):
    """nBits for the block after `window`.

    `window` is the last PAST_BLOCKS blocks, oldest first, each a dict with
    `nbits` and `time`. Returns the compact nBits the next block must carry.
    """
    if len(window) < PAST_BLOCKS:
        return target_to_compact(pow_limit)

    newest_first = list(reversed(window[-PAST_BLOCKS:]))

    avg = 0
    for n, blk in enumerate(newest_first, start=1):
        t = compact_to_target(blk["nbits"])
        if n == 1:
            avg = t
        else:
            avg = (avg * n + t) // (n + 1)

    actual = newest_first[0]["time"] - newest_first[-1]["time"]
    if actual < TARGET_TIMESPAN // CLAMP:
        actual = TARGET_TIMESPAN // CLAMP
    if actual > TARGET_TIMESPAN * CLAMP:
        actual = TARGET_TIMESPAN * CLAMP

    new = (avg * actual) // TARGET_TIMESPAN
    if new > pow_limit:
        new = pow_limit
    return target_to_compact(new)


# ---------------------------------------------------------------------------
#  The real chain, read over RPC in batches
# ---------------------------------------------------------------------------

def rpc_conf(conf_path):
    user = pw = None
    port = 19554
    try:
        for line in open(conf_path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if line.startswith("rpcuser="):
                user = line.split("=", 1)[1]
            elif line.startswith("rpcpassword="):
                pw = line.split("=", 1)[1]
            elif line.startswith("rpcport="):
                port = int(line.split("=", 1)[1])
    except OSError:
        return None
    if not (user and pw):
        return None
    return user, pw, port


def rpc_batch(url, auth, calls):
    req = urllib.request.Request(
        url, data=json.dumps(calls).encode(),
        headers={"Content-Type": "application/json", "Authorization": auth})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def read_chain(conf_path, limit=None):
    """[(height, time, nbits)] from genesis to the tip, in order."""
    import base64
    c = rpc_conf(conf_path)
    if c is None:
        return None, f"no rpcuser/rpcpassword in {conf_path}"
    user, pw, port = c
    url = f"http://127.0.0.1:{port}/"
    auth = "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()

    try:
        info = rpc_batch(url, auth, [{"jsonrpc": "1.0", "id": 0,
                                      "method": "getblockchaininfo",
                                      "params": []}])[0]["result"]
    except Exception as e:
        return None, f"the node did not answer: {e}"
    tip = info["blocks"]
    if limit:
        tip = min(tip, limit)

    blocks = []
    STEP = 500
    for start in range(0, tip + 1, STEP):
        hs = [{"jsonrpc": "1.0", "id": h, "method": "getblockhash",
               "params": [h]} for h in range(start, min(start + STEP, tip + 1))]
        got = rpc_batch(url, auth, hs)
        hashes = [(r["id"], r["result"]) for r in got if r.get("result")]
        heads = [{"jsonrpc": "1.0", "id": hid, "method": "getblockheader",
                  "params": [bh]} for hid, bh in hashes]
        for r in rpc_batch(url, auth, heads):
            if r.get("result"):
                b = r["result"]
                blocks.append((b["height"], b["time"], int(b["bits"], 16)))
    blocks.sort()
    return blocks, None


def pow_limit_from_source(repo):
    """The testnet powLimit, read from chainparams.cpp rather than assumed."""
    p = os.path.join(repo, "src", "wam", "chainparams.cpp")
    try:
        text = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return POW_LIMIT_DEFAULT
    # The testnet block sets powLimit from a uint256S("00000fff...") literal.
    m = re.findall(r'powLimit\s*=\s*uint256S\("([0-9a-fA-F]+)"\)', text)
    if len(m) >= 2:
        return int(m[1], 16)      # main, test, regtest -- take testnet's
    if m:
        return int(m[0], 16)
    return POW_LIMIT_DEFAULT


# ---------------------------------------------------------------------------

GRN = "\033[32m"; RED = "\033[31m"; YLW = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"


def validate(blocks, pow_limit):
    """Every block from PAST_BLOCKS to the tip: does the model predict its nBits?"""
    print(f"\n{BLD}does the model reproduce the chain that already exists?{OFF}")
    checked = 0
    bad = []
    for i in range(PAST_BLOCKS, len(blocks)):
        window = [{"nbits": b[2], "time": b[1]}
                  for b in blocks[i - PAST_BLOCKS:i]]
        want = blocks[i][2]
        got = dgw(window, pow_limit)
        checked += 1
        if got != want:
            bad.append((blocks[i][0], want, got))

    if not checked:
        print(f"  {YLW}no block was compared -- this proves nothing{OFF}")
        return 2
    if bad:
        print(f"  {RED}FAIL{OFF}  {len(bad)} of {checked} blocks disagree")
        for h, want, got in bad[:6]:
            print(f"        height {h}: chain says {want:#010x}, "
                  f"model says {got:#010x}")
        print("\n        The model is wrong. Nothing below it can be believed.")
        return 1
    print(f"  {GRN}ok{OFF}    {checked} blocks, every one predicted exactly")
    print(f"        heights {blocks[PAST_BLOCKS][0]} to {blocks[-1][0]}")
    return 0


def simulate(blocks, pow_limit, multiple, hours=1):
    """A hash rate step up and back down, measured in blocks and minutes.

    The chain's own tail is the starting state, so this begins from the
    difficulty the network actually has rather than from an invented one.
    """
    print(f"\n{BLD}a {multiple}x hash rate arrival, then departure{OFF}")

    window = [{"nbits": b[2], "time": b[1]} for b in blocks[-PAST_BLOCKS:]]
    t = window[-1]["time"]

    # Interval between blocks at a given hash rate multiple: the network needs
    # TARGET_SPACING at 1x, so m times the hash rate finds them m times
    # faster, for whatever difficulty is current. Difficulty enters through
    # the target: interval = spacing * (target_at_1x / target_now) / m.
    base_target = compact_to_target(window[-1]["nbits"])

    def interval(nbits, m):
        tgt = compact_to_target(nbits)
        # A smaller target is harder, so it takes proportionally longer.
        secs = TARGET_SPACING * (base_target / tgt) / m
        return max(1, int(round(secs)))

    rows = []
    nbits = dgw(window, pow_limit)
    phase_blocks = max(1, int(hours * 3600 / TARGET_SPACING))

    # Phase 1: the visitor is here.
    for i in range(phase_blocks):
        dt = interval(nbits, multiple)
        t += dt
        window.append({"nbits": nbits, "time": t})
        rows.append(("with", i + 1, nbits, dt))
        nbits = dgw(window, pow_limit)

    worst = 0
    recovered_at = None
    # Phase 2: they leave. How long until blocks come every two minutes again?
    for i in range(600):
        dt = interval(nbits, 1)
        t += dt
        window.append({"nbits": nbits, "time": t})
        rows.append(("after", i + 1, nbits, dt))
        worst = max(worst, dt)
        nbits = dgw(window, pow_limit)
        if dt <= TARGET_SPACING * 1.25 and recovered_at is None and i > 0:
            recovered_at = i + 1
            break

    d0 = compact_to_target(rows[0][2])
    dmin = min(compact_to_target(r[2]) for r in rows)
    print(f"  difficulty rose by a factor of {d0 / dmin:.1f} while they mined")
    print(f"  the slowest block after they left: {worst // 60} min {worst % 60} s")
    if recovered_at:
        mins = sum(r[3] for r in rows if r[0] == "after") // 60
        print(f"  back to ~2-minute blocks after {recovered_at} block(s), "
              f"about {mins} minutes")
    else:
        print(f"  {RED}did not return to 2-minute blocks within 600 blocks{OFF}")
    print()
    print("  block-by-block, the first few of each phase:")
    shown = 0
    for phase, n, nb, dt in rows:
        if n <= 3 or (phase == "after" and n <= 6):
            print(f"     {phase:<5} #{n:<3} nBits {nb:#010x}  "
                  f"interval {dt // 60}m{dt % 60:02d}s")
            shown += 1
    return 0 if recovered_at else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--validate", action="store_true")
    ap.add_argument("--simulate", type=float, metavar="MULTIPLE")
    ap.add_argument("--hours", type=float, default=1.0)
    ap.add_argument("--conf", default="/root/.wam/wam.conf")
    ap.add_argument("--cache", default="/tmp/wam-chain.json")
    a = ap.parse_args()

    if not (a.validate or a.simulate):
        ap.error("nothing asked: pass --validate, --simulate N, or both")

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    pow_limit = pow_limit_from_source(repo)

    blocks = None
    if os.path.exists(a.cache):
        try:
            blocks = [tuple(x) for x in json.load(open(a.cache))]
        except Exception:
            blocks = None
    if blocks is None:
        blocks, err = read_chain(a.conf)
        if blocks is None:
            print(f"\n  {YLW}could not read the chain: {err}{OFF}")
            print("  This check has to run on a host with a synced node.\n")
            return 2
        try:
            json.dump(blocks, open(a.cache, "w"))
        except OSError:
            pass

    print(f"  chain: {len(blocks)} blocks, heights {blocks[0][0]}..{blocks[-1][0]}")
    print(f"  powLimit from chainparams.cpp: {pow_limit:#x}")

    rc = 0
    if a.validate:
        rc = validate(blocks, pow_limit)
        if rc != 0:
            return rc
    if a.simulate:
        rc = simulate(blocks, pow_limit, a.simulate, a.hours)
    print()
    return rc


if __name__ == "__main__":
    sys.exit(main())

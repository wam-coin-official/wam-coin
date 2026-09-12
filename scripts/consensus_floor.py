#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  consensus_floor.py -- the oldest release a node may run and still be valid
# ===========================================================================
#
#      python3 scripts/consensus_floor.py
#      python3 scripts/consensus_floor.py --explain
#
#  WHY THIS EXISTS
#
#  check_peer_versions.py asked whether every independent operator was on the
#  newest release, and warned that anyone older "will reject every valid
#  block and fork off at height 1".
#
#  That was true when the newest release was the one that changed consensus.
#  It stopped being true the moment v0.1.6 shipped -- a miner fix that
#  touches no consensus rule -- and within an hour of upgrading our own nodes
#  the check was telling us that a node on v0.1.5 would be thrown off the
#  network. v0.1.5 is correct and will stay correct.
#
#  A launch-critical warning that cries wolf is worse than none. The next
#  person to read it is an operator who did exactly the right thing and is
#  being told it was not enough.
#
#  HOW THE ANSWER IS FOUND
#
#  Not from a constant somebody has to remember to bump -- this project has
#  been bitten three separate times by one fact living in two places. It is
#  derived from the repository:
#
#    for each tag, newest first, read the consensus values out of
#    src/wam/chainparams.cpp and src/wam/wam-params.h at that tag; the floor
#    is the newest tag whose values differ from the tag before it.
#
#  Comments, whitespace and anything that is not a consensus value are
#  stripped first, so reformatting a file or rewriting a comment cannot move
#  the floor. Only the values can.
# ===========================================================================

import argparse
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

CHAINPARAMS = "src/wam/chainparams.cpp"
PARAMS = "src/wam/wam-params.h"

# Every line in chainparams.cpp that carries a value a node enforces or a
# value that decides which network it is even on. A node disagreeing about
# any of these is a node on a different chain.
CHAINPARAMS_PATTERNS = [
    r'WAM_(?:FOUNDER|TREASURY)_ADDRESS_(?:MAINNET|TESTNET)\s*=\s*"[^"]*"',
    r'pchMessageStart\[\d\]\s*=\s*0x[0-9a-fA-F]+',
    r'nDefaultPort\s*=\s*\d+',
    r'/\*nNonce=\*/\s*\d+',
    r'hashGenesisBlock\s*==\s*uint256S\("0x[0-9a-f]{64}"\)',
    r'consensus\.\w+\s*=\s*[^;]+',
    r'bech32_hrp\s*=\s*"[^"]*"',
    r'base58Prefixes\[[A-Z_]+\]\s*=[^;]+',
]

# wam-params.h is nothing but consensus numbers, so every value line counts.
PARAMS_PATTERN = r'^\s*(?:static\s+const|constexpr|#define)\s+.+$'

# Fields that `consensus.\w+` catches and that this file must not count.
#
# The test at the head of CHAINPARAMS_PATTERNS is the definition: "a node
# disagreeing about any of these is a node on a different chain." Exactly one
# field assigned through `consensus.` fails that test.
#
# nMinimumChainWork is the least total work a header chain must carry before a
# node will begin to trust it -- an anti-DoS policy, so that a fresh node
# cannot be walked onto a cheap fabricated history by the first peer it meets.
# Two nodes with different values accept identical blocks. It cannot put them
# on different chains. What it can do is stop a node syncing at all, which is
# a liveness question, and scripts/check_min_chain_work.py exists for it.
#
# Counting it here is not harmless. v0.1.8 set the testnet value -- leaving
# mainnet at zero -- and that moved this floor to v0.1.8, which made
# release.yml refuse to publish a release whose tag carried no MANDATORY line.
# The two remedies available at that moment were both wrong: write a MANDATORY
# line, and every channel is told UPDATE REQUIRED for a release no node needs
# -- spending the one warning that has to be believed on launch day, which is
# precisely the failure release.yml's own comments describe; or do not publish.
#
# A v0.1.7 node has zero there, follows this chain exactly as before, and
# accepts every block a v0.1.8 node accepts. It is not on a different chain,
# so v0.1.8 is not a floor.
NOT_A_VALIDITY_RULE = (
    "nMinimumChainWork",
)


def git(*args):
    r = subprocess.run(["git", "-C", str(REPO), *args],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def ver_tuple(tag):
    return tuple(int(x) for x in re.findall(r"\d+", tag.lstrip("v")))


def tags():
    out = git("tag", "-l", "v*") or ""
    return sorted((t.strip() for t in out.split("\n") if t.strip()),
                  key=ver_tuple)


def fingerprint_text(chainparams, params):
    """Every consensus value in those two files, normalised, in a stable
    order. Separated from the git plumbing so the same definition serves the
    local walk below and the over-the-network comparison install.sh makes --
    two places asking 'did consensus change' must not answer differently."""
    if chainparams is None or params is None:
        return None
    values = []

    # Strip comments before matching, so a sentence that quotes a value --
    # and chainparams.cpp is full of those, deliberately -- is not read as
    # the value itself.
    text = re.sub(r"/\*(?!nNonce=).*?\*/", " ", chainparams, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    for pat in CHAINPARAMS_PATTERNS:
        for m in re.findall(pat, text):
            v = re.sub(r"\s+", " ", m).strip()
            # See NOT_A_VALIDITY_RULE. Dropped after matching rather than by
            # narrowing the pattern, so that `consensus.` still catches every
            # field by default and an exception has to be named and argued
            # for -- a new consensus value must never be missed because a
            # regular expression was tightened to exclude a different one.
            if any(("." + f) in v for f in NOT_A_VALIDITY_RULE):
                continue
            values.append(v)

    text = re.sub(r"/\*.*?\*/", " ", params, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    for line in text.split("\n"):
        if re.match(PARAMS_PATTERN, line):
            values.append(re.sub(r"\s+", " ", line).strip())

    return "\n".join(sorted(set(values)))


def fingerprint(tag):
    """Every consensus value at that tag, read from this repository."""
    return fingerprint_text(git("show", f"{tag}:{CHAINPARAMS}"),
                            git("show", f"{tag}:{PARAMS}"))


def fetch_tag(tag, repo="wam-coin-official/wam-coin"):
    """The two consensus files at a tag, read from GitHub rather than from
    here. A checkout that is behind has tags that are behind too, so it
    cannot answer this question about itself."""
    import urllib.request
    out = []
    for path in (CHAINPARAMS, PARAMS):
        url = f"https://raw.githubusercontent.com/{repo}/{tag}/{path}"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "wam-consensus-floor"})
            with urllib.request.urlopen(req, timeout=20) as r:
                out.append(r.read().decode("utf-8", "replace"))
        except Exception:
            return None, None
    return out[0], out[1]


def floor():
    """(tag, reason) -- the newest tag at which consensus changed."""
    ts = tags()
    if not ts:
        return None, "the repository has no version tags"

    prints = {}
    for t in ts:
        prints[t] = fingerprint(t)

    usable = [t for t in ts if prints[t] is not None]
    if not usable:
        return None, "no tag has readable consensus files"

    for i in range(len(usable) - 1, 0, -1):
        if prints[usable[i]] != prints[usable[i - 1]]:
            return usable[i], f"consensus values last changed in {usable[i]}"

    return usable[0], f"consensus has not changed since {usable[0]}"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--explain", action="store_true",
                    help="show what changed at the floor, and at every tag")
    ap.add_argument("--compare-remote", nargs=2, metavar=("TAG_A", "TAG_B"),
                    help="fetch both tags from GitHub and say whether any "
                         "consensus value differs between them; exit 2 if it "
                         "does, 0 if not, 1 if they could not be read")
    args = ap.parse_args()

    # Asked by install.sh, from a clone whose own tags may be out of date.
    # A MANDATORY marker in the release notes is the fast answer, but it
    # depends on somebody having written it -- and the one consensus release
    # this project has made, v0.1.5, was published without one. This derives
    # the answer from the files instead, so the guard holds even when the
    # marker is missing.
    if args.compare_remote:
        a, b = args.compare_remote
        fa = fingerprint_text(*fetch_tag(a))
        fb = fingerprint_text(*fetch_tag(b))
        if fa is None or fb is None:
            print("unreadable")
            return 1
        if fa == fb:
            print("same")
            return 0
        print("differs")
        sa, sb = set(fa.split("\n")), set(fb.split("\n"))
        for line in sorted(sb - sa):
            print(f"  + {line[:100]}")
        for line in sorted(sa - sb):
            print(f"  - {line[:100]}")
        return 2

    tag, reason = floor()
    if tag is None:
        print(reason, file=sys.stderr)
        return 1

    if not args.explain:
        print(tag)
        return 0

    print(f"\n  consensus floor: {tag}")
    print(f"  {reason}\n")
    ts = tags()
    prev = None
    for t in ts:
        f = fingerprint(t)
        if f is None:
            print(f"    {t:<8} (consensus files not present)")
        elif prev is None:
            print(f"    {t:<8} first tag with consensus values")
        elif f != prev:
            a, b = set(prev.split("\n")), set(f.split("\n"))
            for line in sorted(b - a):
                print(f"    {t:<8} + {line[:88]}")
            for line in sorted(a - b):
                print(f"    {t:<8} - {line[:88]}")
        else:
            print(f"    {t:<8} unchanged")
        if f is not None:
            prev = f
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())

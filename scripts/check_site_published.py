#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_site_published.py -- is the live site the site in this repository?
# ===========================================================================
#
#      python3 scripts/check_site_published.py
#
#  WHY THIS EXISTS
#
#  On 15 September 2026, the day mainnet opened, two corrections were made to
#  site/ on main, committed, pushed, and reported as published:
#
#    - SECURITY: the page claimed a bounty had already been paid. Nothing had.
#    - the mining guide sent miners to port 13333, which had stopped existing
#      at 00:00 UTC when the testnet pool was converted.
#
#  Neither reached wamcoin.org. GitHub Pages serves the gh-pages branch, which
#  is generated from site/ by scripts/publish_site.sh, and that script was
#  never run. So for two days the live site told the world a payment had been
#  made that had not, and told miners to connect to a dead port -- while the
#  repository, every commit message, and everything said to the founder were
#  correct.
#
#  It was found by an outside security researcher asking, by email, for the
#  transaction id of the payment the page claimed.
#
#  check_published_claims.py compares documents to consensus. audit_repo.sh
#  compares files to each other. check_deployed_code.sh compares the servers
#  to origin/main. Nothing compared the LIVE WEBSITE to the repository, and a
#  correction that is committed but not published is worse than no correction:
#  it makes everyone who reads the commit believe the lie is gone.
#
#  EXIT CODES, this project's convention
#
#      0  every page checked is byte-identical to site/ in this repository
#      1  a live page differs -- the world is reading something else
#      2  the question could not be put (no network, a page 404s)
# ===========================================================================

import hashlib
import os
import sys
import urllib.error
import urllib.request

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"

BASE = os.environ.get("WAM_SITE", "https://wamcoin.org")
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(HERE, "site")

# The pages a stranger actually lands on. Every one of them has carried a
# wrong number at some point in this project's short life.
PAGES = [
    ("index.html", "/"),
    ("mine/index.html", "/mine/"),
    ("start/index.html", "/start/"),
    ("security/index.html", "/security/"),
    ("pool/index.html", "/pool/"),
    ("whitepaper/index.html", "/whitepaper/"),
]


def fetch(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": "wam-site-check",
        # Pages sits behind a CDN. Without this a cached copy can answer for
        # minutes after a publish, and the check would then be measuring the
        # cache rather than the site.
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def main():
    print(f"\n{BLD}is the live site the site in this repository?{OFF}")
    print(f"  {BASE}\n")

    differ, unreadable, same = [], [], 0

    for rel, path in PAGES:
        local_path = os.path.join(SITE, rel.replace("/", os.sep))
        if not os.path.exists(local_path):
            continue
        with open(local_path, "rb") as fh:
            want = fh.read()

        try:
            got = fetch(BASE.rstrip("/") + path)
        except Exception as e:
            print(f"  {YEL}??{OFF}    {path:<16} could not be read ({e})")
            unreadable.append(path)
            continue

        if hashlib.sha256(got).digest() == hashlib.sha256(want).digest():
            print(f"  {GRN}ok{OFF}    {path:<16} matches site/{rel}")
            same += 1
        else:
            print(f"  {RED}FAIL{OFF}  {path:<16} DIFFERS from site/{rel}")
            print(f"        live {len(got)} bytes, repo {len(want)} bytes")
            differ.append(path)

    print()
    if differ:
        print(f"  {RED}{len(differ)} live page(s) are not what this repository says{OFF}")
        print("  The site is served from the gh-pages branch, which is generated.")
        print("  Publish it:  bash scripts/publish_site.sh")
        print("  A correction that is committed but not published is worse than")
        print("  none: everyone reading the commit believes it is fixed.\n")
        return 1
    if unreadable and same == 0:
        print(f"  {YEL}nothing could be read -- this is not a pass{OFF}\n")
        return 2
    if unreadable:
        print(f"  {YEL}{same} page(s) match; {len(unreadable)} could not be read{OFF}\n")
        return 2
    print(f"  {GRN}all {same} page(s) live are byte-identical to this repository{OFF}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

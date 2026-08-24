#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_docs_version.py -- do the instructions name a release that exists?
# ===========================================================================
#
#      python3 scripts/check_docs_version.py
#
#  WHY THIS EXISTS
#
#  docs/START_HERE.md and its Arabic twin are the pages written for someone
#  who has never run a node. They give exact commands to copy:
#
#      curl -LO .../releases/download/v0.1.3/wam-coin-v0.1.3-...tar.gz
#      tar -xzf wam-coin-v0.1.3-...tar.gz
#      cd wam-coin-v0.1.3/bin
#
#  Four releases later those files had been withdrawn, deliberately, because
#  v0.1.3 could not send a transaction and v0.1.4 enforced a treasury address
#  that would fork a node off mainnet at height 1. Both were superseded and
#  their binaries removed -- and the guide still pointed at them.
#
#  So the first command a beginner ran returned 404, and the page written to
#  make them feel capable made them feel stupid instead. It was found by the
#  founder reading his own documentation, not by any check here.
#
#  WHAT IS CHECKED
#
#  Every vX.Y.Z in the documentation is compared against the releases that
#  actually exist on GitHub, and against which of those still have binaries.
#  A version that was withdrawn is worse than one that is merely old: the
#  download does not fail loudly, the tag page loads and looks normal, and
#  only the asset is gone.
#
#  /releases/latest is deliberately NOT used to find the newest. It excludes
#  pre-releases, every WAM release is marked one until 1.0, and it answers
#  404 for this repository -- a check that could never pass.
# ===========================================================================

import json
import pathlib
import re
import sys
import urllib.request

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"

REPO = pathlib.Path(__file__).resolve().parent.parent
API = "https://api.github.com/repos/wam-coin-official/wam-coin/releases?per_page=20"

# Where a stale version actually costs someone something. Commit messages,
# changelogs and design notes name old versions on purpose -- that is history,
# not instruction.
DOCS = [
    "docs/START_HERE.md",
    "docs/START_HERE_AR.md",
    "README.md",
    "docs/BUILD.md",
    "docs/POOL_OPERATOR.md",
    "docs/SERVER_SETUP.md",
    "site/index.html",
]

# A version number is only an instruction when the reader is being told to
# fetch that exact thing. Every other mention is prose, and prose about old
# versions is usually the most important prose in the file:
#
#     "a node left on v0.1.4 will reject every valid block on launch day
#      and fork itself off the network"
#
# The first version of this matched every `vX.Y.Z` in the document and so it
# failed on that sentence -- reporting the warning we most want operators to
# read as a dead download link. A check that objects to correct text is worse
# than no check: it teaches its reader to skip the output. On 2026-08-19
# three faults were live at once behind exactly that habit.
#
# So the contexts are named one by one. Each alternative captures the version.
INSTRUCTION = re.compile(
    r"releases/download/v(\d+\.\d+\.\d+)/"      # the URL people curl
    r"|wam-(?:coin|miner)-v(\d+\.\d+\.\d+)"     # the tarball, and the directory
    r"|\[v(\d+\.\d+\.\d+)\]\("                  # "the release is [v0.1.5](...)"
)


def instructed_versions(text):
    """Every version the document actually tells someone to obtain."""
    out = set()
    for m in INSTRUCTION.finditer(text):
        v = next((g for g in m.groups() if g), None)
        if v:
            out.add(v)
    return out
_fails = []


def ok(m):   print(f"  {GRN}ok{OFF}    {m}")
def bad(m):  print(f"  {RED}FAIL{OFF}  {m}"); _fails.append(m)
def warn(m): print(f"  {YEL}!!{OFF}    {m}")


def releases():
    req = urllib.request.Request(API, headers={"User-Agent": "wam-check-docs"})
    with urllib.request.urlopen(req, timeout=25) as r:
        data = json.load(r)
    out = {}
    for rel in data:
        tag = rel["tag_name"].lstrip("v")
        out[tag] = {
            "title": rel["name"],
            "has_binaries": any(a["name"].endswith(".tar.gz") for a in rel["assets"]),
        }
    newest = data[0]["tag_name"].lstrip("v") if data else None
    return out, newest


def main():
    print(f"\n{BLD}the version the instructions tell people to download{OFF}")
    try:
        rels, newest = releases()
    except Exception as e:
        bad(f"could not read the releases from GitHub: {e}")
        print()
        return 1

    if not newest:
        bad("the repository has no releases at all")
        print()
        return 1
    ok(f"newest release: v{newest}")

    checked = 0
    for rel_path in DOCS:
        p = REPO / rel_path
        if not p.exists():
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        found = instructed_versions(text)
        if not found:
            continue
        checked += 1
        for v in sorted(found):
            info = rels.get(v)
            if info is None:
                # Not one of ours: Bitcoin Core v28.1, RandomX v1.2.1, and so on.
                continue
            if v == newest:
                ok(f"{rel_path}: v{v}")
            elif not info["has_binaries"]:
                bad(f"{rel_path} tells the reader to download v{v}, whose binaries "
                    f"were withdrawn. The tag page still loads, so the download "
                    f"just 404s and the first command a beginner runs fails. "
                    f"Newest is v{newest}.")
            else:
                warn(f"{rel_path} names v{v}, which still has binaries but is not "
                     f"the newest (v{newest})")

    if checked == 0:
        bad("no documentation file was read -- this proves nothing")

    print()
    if _fails:
        print(f"  {RED}{len(_fails)} document(s) point at a release nobody can download{OFF}")
        print("  The guide for people who have never run a node is the one page\n"
              "  where a dead link costs the most.\n")
        return 1
    print(f"  {GRN}every documented version is one that exists{OFF}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

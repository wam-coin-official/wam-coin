#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_links.py -- does every link in every document point at something?
# ===========================================================================
#
#      python3 scripts/check_links.py
#
#  WHY THIS EXISTS
#
#  audit_repo.sh already refuses a broken file reference, and has since
#  August. It looks for paths beginning with one of a dozen named top-level
#  directories:
#
# wam:quote-begin
#      (brand|docs|scripts|genesis|deploy|site|pool|explorer|bots|miner)/...
# wam:quote-end
#
#  integration/ is not in that list, and neither is any RELATIVE link -- a
#  document saying `wallet-confs/x.conf` names a file beside itself, with no
#  top-level directory in it at all.
#
#  So on 6 September 2026, integration/blockdx/PR.md and NOTES.md both linked
#  to
#
# wam:quote-begin
#      wallet-confs/wamcoin--v0.1.3.conf
#      xbridge-confs/wamcoin--v0.1.3.conf
# wam:quote-end
#
#  which have not existed since the coin's prefix changed from `wamcoin` to
#  `wam` and the configs moved to v0.1.6. PR.md is the text submitted to the
#  BlockDX repository as a pull request: we would have described our own
#  files by names nobody could find, to the people deciding whether to list
#  this coin.
#
#  A path is relative to the document that writes it. That is the whole idea,
#  and no list of directory names can express it.
#
#  WHAT IS NOT CHECKED
#
#  http(s) links. Reaching the network makes a check that fails when a site
#  is briefly down, and a check that cries wolf is one people stop reading --
#  which is how three faults stayed live at once on 19 August. Anchors
#  (#section) are not resolved either; a wrong anchor lands the reader on the
#  right page.
# ===========================================================================

import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts" / "lib"))
import quoted  # noqa: E402  -- needs the path above

GRN, RED, YLW, BLD, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[0m"

# Markdown links only -- [text](target). A bare `path/like/this.ext` in
# backticks is not followed, and the distinction is not cosmetic.
#
# The integration notes are tables of "our file -> where it goes in THEIR
# repository":
#
# wam:quote-begin
#     | [`chainparams.py`](chainparams.py) | `basicswap/interface/wam/chainparams.py` |
# wam:quote-end
#
# The left cell is a link to a file here and must resolve. The right cell is
# a path inside BasicSwap's tree, correct and absent from this repository by
# definition. Following backticked paths reported twenty of those as broken
# on the first run -- a check objecting to correct text, which teaches its
# reader to skip the output, and is how three faults stayed live at once on
# 19 August.
#
# The blockdx fault that prompted this check was in the LEFT cell, so nothing
# is lost: a link is a claim that a file is there, and a code span is prose.
MD_LINK = re.compile(r"\[[^\]]*\]\(\s*([^)\s]+)")

SKIP_PREFIX = ("http://", "https://", "mailto:", "#", "ftp://", "//")

# Named on purpose without existing: created by the reader, or kept out by
# .gitignore. Each is a decision, and git is asked about the rest.
EXPECTED_ABSENT = re.compile(r"config\.json$|config-mainnet\.json$|wam\.conf$")


def tracked_markdown():
    out = subprocess.run(["git", "ls-files", "*.md"], cwd=str(REPO),
                         capture_output=True, text=True).stdout.split()
    return sorted(out)


def targets(text):
    """Every local path a document points at, with its line number."""
    found = []
    for i, line in quoted.unquoted_lines(text):
        for m in MD_LINK.finditer(line):
            found.append((i, m.group(1)))
    return found


def main():
    print(f"\n{BLD}every link points at something that is here{OFF}")

    docs = tracked_markdown()
    if not docs:
        print(f"  {RED}FAIL{OFF}  no markdown was found -- this proves nothing")
        print()
        return 2

    broken, checked = [], 0
    for rel in docs:
        path = REPO / rel
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line_no, target in targets(text):
            if target.startswith(SKIP_PREFIX):
                continue
            target = target.split("#", 1)[0].strip()
            if not target:
                continue
            if EXPECTED_ABSENT.search(target):
                continue
            # Relative to the document that writes it -- which is the point.
            resolved = (path.parent / target).resolve()
            checked += 1
            if resolved.exists():
                continue
            # A repository-root path written without a leading ./ is the other
            # common form, so it is tried before anything is called broken.
            if (REPO / target.lstrip("/")).exists():
                continue
            if subprocess.run(["git", "check-ignore", "-q", target],
                              cwd=str(REPO)).returncode == 0:
                continue
            broken.append((rel, line_no, target))

    if checked == 0:
        print(f"  {RED}FAIL{OFF}  no link was resolved at all -- this proves nothing")
        print()
        return 2

    if broken:
        print(f"  {RED}FAIL{OFF}  {len(broken)} link(s) point at nothing")
        for rel, line_no, target in broken[:12]:
            print(f"          {rel}:{line_no}  ->  {target}")
        if len(broken) > 12:
            print(f"          ... and {len(broken) - 12} more")
        print()
        print("        A path is relative to the document that writes it.")
        print("        Some of these documents are submitted to other projects.")
        print()
        return 1

    print(f"  {GRN}ok{OFF}    {checked} link(s) in {len(docs)} document(s) resolve")
    print()
    print(f"  {GRN}{BLD}nothing points at a file that is not here{OFF}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

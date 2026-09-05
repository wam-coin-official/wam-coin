#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  set_version.py -- move every version the reader is told to fetch, at once
# ===========================================================================
#
#      python3 scripts/set_version.py 0.1.6
#      python3 scripts/set_version.py 0.1.6 --dry-run
#
#  WHY THIS EXISTS
#
#  Cutting v0.1.5 changed one line in patch_upstream.py. The two beginner
#  guides still said v0.1.4, whose binaries had been withdrawn, so the first
#  command on the page written to make a stranger feel capable answered 404.
#  The same thing had happened one release earlier with v0.1.3, and that time
#  the founder found it by reading his own documentation.
#
#  Twice is a mechanism, not an accident: the version lives in two kinds of
#  place, they are edited by different hands at different moments, and
#  nothing makes them move together. So they move together here.
#
#  WHAT IT WILL NOT TOUCH
#
#  Prose that names an old version on purpose. This sentence must survive
#  every release unchanged, because it is the warning operators need:
#
#      a node left on v0.1.4 will reject every valid block on launch day
#      and fork itself off the network
#
#  Only the contexts where a reader is being told to obtain that exact
#  artifact are rewritten -- the download URL, the tarball, the directory
#  they cd into, and a version used as the link text for the releases page.
#  These are the same contexts check_docs_version.py checks, deliberately:
#  the writer and the auditor must agree on what counts as an instruction.
# ===========================================================================

import argparse
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# The build's own idea of what it is.
CLIENT_VERSION = REPO / "scripts" / "patch_upstream.py"
CLIENT_RE = re.compile(r'(WAM_CLIENT_VERSION\s*=\s*")(\d+\.\d+\.\d+)(")')

# Documents that tell a reader to download something.
#
# Discovered, not listed. The list used to be three names, and on 5 September
# docs/MINE.md was added -- nine commands, four of them naming v0.1.6 -- and
# this script could not see it. The next release would have moved every other
# page and left that one sending strangers at a version that no longer
# existed, which is the exact failure this script was written for after v0.1.5
# did it to the two guides.
#
# A hand-kept list of files goes stale the moment somebody adds a page, in the
# same way "four accounts" in CHANNELS.txt went stale when there were five.
# So: any tracked markdown that carries a download instruction is a document
# that tells a reader to download something.
def _discover_docs():
    import subprocess
    out = subprocess.run(["git", "ls-files", "*.md"], cwd=REPO,
                         capture_output=True, text=True).stdout.split()
    found = []
    for rel in out:
        p = REPO / rel
        try:
            t = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if any(rx.search(t) for rx in INSTRUCTIONS):
            found.append(rel)
    return sorted(found)

# Each pattern keeps its surroundings and replaces only the number. Written
# as (prefix)(version)(suffix) so the substitution cannot damage the line.
INSTRUCTIONS = [
    re.compile(r"(releases/download/v)(\d+\.\d+\.\d+)(/)"),
    re.compile(r"(wam-(?:coin|miner)-v)(\d+\.\d+\.\d+)()"),
    re.compile(r"(\[v)(\d+\.\d+\.\d+)(\]\()"),
]

DOCS = _discover_docs()

GRN = "\033[32m"; YEL = "\033[33m"; RED = "\033[31m"; BLD = "\033[1m"; OFF = "\033[0m"


def rewrite(text, version, patterns):
    """Apply every pattern, returning the new text and what actually moved."""
    moved = []

    def sub(m):
        old = m.group(2)
        if old == version:
            return m.group(0)
        moved.append(old)
        return m.group(1) + version + m.group(3)

    for p in patterns:
        text = p.sub(sub, text)
    return text, moved


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("version", help="the new version, without a leading v (e.g. 0.1.6)")
    ap.add_argument("--dry-run", action="store_true",
                    help="say what would change and write nothing")
    args = ap.parse_args()

    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        print(f"  {RED}not a version: {args.version}{OFF}  (expected e.g. 0.1.6)")
        return 2

    v = args.version
    print(f"\n{BLD}setting every documented version to v{v}{OFF}")
    touched = []

    # 1. the build
    text = CLIENT_VERSION.read_text(encoding="utf-8")
    new, moved = rewrite(text, v, [CLIENT_RE])
    if moved:
        print(f"  {GRN}WAM_CLIENT_VERSION{OFF}  {moved[0]} -> {v}   "
              f"scripts/patch_upstream.py")
        if not args.dry_run:
            CLIENT_VERSION.write_text(new, encoding="utf-8", newline="\n")
        touched.append("scripts/patch_upstream.py")
    else:
        print(f"  {YEL}WAM_CLIENT_VERSION{OFF}  already v{v}")

    # 2. the instructions
    for rel in DOCS:
        p = REPO / rel
        if not p.exists():
            continue
        text = p.read_text(encoding="utf-8")
        new, moved = rewrite(text, v, INSTRUCTIONS)
        if not moved:
            continue
        olds = ", ".join(sorted(set(moved)))
        print(f"  {GRN}{rel}{OFF}  {len(moved)} instruction(s): v{olds} -> v{v}")
        if not args.dry_run:
            p.write_text(new, encoding="utf-8", newline="\n")
        touched.append(rel)

    # 3. the pages built from those documents
    #
    # Rebuilt whenever ANY document moved, not only when a START_HERE did.
    #
    # The condition here used to be `any(d.startswith("docs/START_HERE"))`,
    # written when those two were the only documents with a version in them.
    # On 5 September docs/MINE.md arrived carrying eight of them, and if a
    # release had only touched that file the site would have kept serving the
    # previous version's download commands while every markdown file said
    # otherwise. It happened to work this time because START_HERE moved as
    # well, and "happens to work" is the thing this repository keeps finding
    # at the bottom of its faults.
    #
    # Which pages exist is build_pages.py's business, so it is asked rather
    # than told: the names below come from its output.
    if not args.dry_run and touched:
        r = subprocess.run([sys.executable, str(REPO / "scripts" / "build_pages.py")],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  {RED}build_pages.py failed{OFF}\n{r.stdout}{r.stderr}")
            return 1
        built = re.findall(r"^\s*(/[a-z-]+/)\s", r.stdout, flags=re.M)
        print(f"  {GRN}{len(built)} page(s){OFF}  regenerated: {' '.join(built)}")
        touched += [f"site{p}index.html" for p in built]

    if not touched:
        print(f"\n  {GRN}nothing to do -- everything already says v{v}{OFF}\n")
        return 0

    print()
    if args.dry_run:
        print("  --dry-run: nothing was written\n")
        return 0

    print(f"  {len(touched)} file(s) written. Next:\n")
    print(f"    git add -A && git commit")
    print(f"    git tag -a v{v} -m ...        # the tag message is the release note")
    print(f"    git push origin main && git push origin v{v}\n")
    print("  check_docs_version.py will fail until the release is published.")
    print("  That is the correct order: the documents name the tag, the tag is")
    print("  built from the documents.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

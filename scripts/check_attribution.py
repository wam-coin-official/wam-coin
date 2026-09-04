#!/usr/bin/env python3
"""No commit added from now on carries an assistant attribution line.

    python3 scripts/check_attribution.py

WHY

The founder asked for these lines to be removed, they were removed, and he
asked that they not come back. They came back: on 4 September 2026 there
were twenty-four of them reachable from HEAD, the oldest 4a97de8 on
24 August, six of them written that same day.

They came back because the removal was a thing to be remembered, and the
default behaviour that adds them never stopped. That is the same failure
that cost this project four other things in one day -- the channel list, its
signature, the site deploy, the release checker -- and the answer each time
was the same: stop relying on remembering.

WHAT IT DOES

Everything reachable from BASELINE is the existing backlog. It is reported,
not failed on, because rewriting it would rewrite v0.1.6 -- the release the
public was told to download on 4 September. The founder's instruction is
that it goes at the next update or maintenance that requires a history
change anyway, and this prints that reminder every run so the moment is not
missed.

Anything NEWER than BASELINE that carries such a line is a new one, and
fails. There is no reason for a new one to exist.

Exit 0 clean, 1 a new commit carries it, 2 the check could not run.
"""

import re
import subprocess
import sys

# HEAD on 4 September 2026, when the instruction was recorded. Everything
# reachable from here is the backlog to be removed later; anything after it
# is a regression.
BASELINE = "f7bbf210bd05b14ba82a09c5d36439f6363973ae"

PATTERNS = [
    r"co-authored-by:\s*claude",
    r"generated with \[?claude code",
    r"claude\.ai/code",
    r"noreply@anthropic\.com",
]
RX = re.compile("|".join(PATTERNS), re.I)

GRN, RED, YLW, BLD, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[0m"


def git(*args):
    r = subprocess.run(["git", *args], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        return None
    return r.stdout


def carriers(rev_range):
    """[(short hash, subject)] for commits in the range whose message matches."""
    out = git("log", "--format=%H%x1f%h%x1f%s%x1f%B%x1e", rev_range)
    if out is None:
        return None
    found = []
    for rec in out.split("\x1e"):
        rec = rec.strip("\n")
        if not rec:
            continue
        parts = rec.split("\x1f")
        if len(parts) < 4:
            continue
        _full, short, subject, body = parts[0], parts[1], parts[2], parts[3]
        if RX.search(body):
            found.append((short, subject))
    return found


def main():
    print()
    print(f"{BLD}no assistant attribution in anything committed from now on{OFF}")

    if git("rev-parse", "--git-dir") is None:
        print(f"  {YLW}skipped{OFF}  not a git repository")
        print()
        return 0

    if git("cat-file", "-e", BASELINE + "^{commit}") is None:
        print(f"  {RED}FAIL{OFF}  the baseline commit {BASELINE[:7]} is not in "
              f"this repository")
        print("        If history was rewritten, update BASELINE in this file")
        print("        to the commit that rewrite produced.")
        print()
        return 2

    # ---- anything of ours, in a tracked file ------------------------
    tracked = git("grep", "-l", "-i", "-E",
                  "co-authored-by: *claude|generated with .?claude code|claude\\.ai/code")
    if tracked:
        names = [n for n in tracked.splitlines()
                 if n.strip() and not n.startswith("scripts/check_attribution.py")]
        if names:
            print(f"  {RED}FAIL{OFF}  {len(names)} tracked file(s) carry an "
                  f"attribution marker")
            for n in names:
                print(f"          {n}")
            print()
            return 1
    print(f"  {GRN}ok{OFF}    no tracked file carries one")

    # ---- new commits ------------------------------------------------
    new = carriers(f"{BASELINE}..HEAD")
    if new is None:
        print(f"  {YLW}skipped{OFF}  HEAD is not a descendant of the baseline")
        print("        Either the branch diverged or history was rewritten.")
        print()
        return 2

    if new:
        print(f"  {RED}FAIL{OFF}  {len(new)} commit(s) added since "
              f"{BASELINE[:7]} carry one")
        for short, subject in new:
            print(f"          {short}  {subject[:64]}")
        print()
        print("        Rewrite the message before pushing:")
        print("          git commit --amend        (the newest one)")
        print("          git rebase -i " + BASELINE[:7] + "   (several)")
        print()
        return 1
    print(f"  {GRN}ok{OFF}    nothing added since {BASELINE[:7]} carries one")

    # ---- the backlog, reported and not failed on --------------------
    old = carriers(BASELINE) or []
    if old:
        print()
        print(f"  {YLW}still to remove:{OFF} {len(old)} older commit(s), "
              f"oldest {old[-1][0]}")
        print("        Left in place deliberately. Removing them rewrites")
        print("        v0.1.6, which the public was told to download on")
        print("        4 September, so it waits for the next update or")
        print("        maintenance that requires a history change anyway --")
        print("        and then it is removed from everywhere at once.")

    print()
    print(f"  {GRN}{BLD}nothing new{OFF}")
    print()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(2)

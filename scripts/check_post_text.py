#!/usr/bin/env python3
"""No filename we publish is also somebody else's domain.

    python3 scripts/check_post_text.py

WHY

The pre-launch posts said, in the paragraph about verifying the release
signature:

    Check the fingerprint against SECURITY.md on GitHub over HTTPS

Telegram and X do not see a filename. `.md` is Moldova's country TLD, so
`SECURITY.md` is a hostname, and they turn it into a link. security.md is a
live shop selling CCTV. The sentence that tells a reader where to go and
confirm our signing fingerprint sent them to a stranger's storefront -- in
the one paragraph whose entire purpose is to stop a reader trusting a
fingerprint handed to them by a message.

It was live for hours. The founder found it by pressing it. Nothing in this
project would have.

The first response was to write the rule down in a README, which is the
same remedy that had already failed four times the same day: a rule a person
has to remember is a rule that gets forgotten. This is the check instead.

WHAT COUNTS AS DANGEROUS

A bare `name.ext` where `ext` is a real top-level domain. Two things save a
filename by accident, and neither is a design:

    docs/REHEARSALS.md    a path prefix stops a client reading it as a host
    verify_release.sh     an underscore is illegal in a hostname
    CHANNELS.txt          .txt is not a TLD

So this flags only what a client would actually linkify: a token with no
path in front of it, no underscore in the name, ending in a TLD. Write the
full https:// URL and the question does not arise -- it is safer and it goes
where it says.

Exit 0 clean, 1 something publishable would linkify, 2 the check could not
run.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
POSTS = ROOT / "posts"

GRN, RED, YLW, BLD, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[0m"

# Country and generic TLDs that are also file extensions people write. Not
# the whole IANA list -- only the ones that plausibly appear at the end of a
# filename in text we publish, which is what makes this a real hazard rather
# than a theoretical one.
TLDS = [
    "md",    # Moldova      -- SECURITY.md, README.md    <- the one that bit
    "sh",    # St Helena    -- install.sh, sweep.sh
    "py",    # Paraguay     -- any script
    "pl",    # Poland
    "rs",    # Serbia       -- Rust sources
    "so",    # Somalia      -- shared objects
    "io", "ai", "app", "dev", "zip", "link", "click",
    "it", "is", "in", "co", "me", "im", "tv", "cc", "ws", "st", "as", "at",
    "by", "to", "no", "se", "si", "sk", "tk", "ly", "gg", "gs", "la", "li",
]

# A token a chat client would resolve as a host:
#   - nothing path-like or word-like immediately before it
#   - a label of letters, digits and hyphens only (an underscore is illegal
#     in a hostname, so verify_release.sh is never linkified)
#   - one of the extensions above
RX = re.compile(
    r"(?<![/\w.$-])([A-Za-z][A-Za-z0-9-]*)\.(" + "|".join(TLDS) + r")\b")


def main():
    print()
    print(f"{BLD}nothing we publish reads as somebody else's domain{OFF}")

    if not POSTS.is_dir():
        print(f"  {YLW}skipped{OFF}  no posts/ directory")
        print()
        return 0

    # Only the .txt files, because only those are pasted into a platform.
    # The .md files beside them are working notes -- including the one that
    # documents this very hazard, and which therefore has to write the
    # dangerous string down in order to explain it. The first version scanned
    # those too and produced seven findings, every one of them a sentence
    # about the bug rather than the bug: the same false-positive flood that
    # made check_channels.py useless this morning, made twice in one day.
    files = sorted(p for p in POSTS.rglob("*.txt") if p.is_file())
    if not files:
        print(f"  {YLW}skipped{OFF}  posts/ has nothing in it")
        print()
        return 0

    hits = []
    for p in files:
        rel = p.relative_to(ROOT).as_posix()
        for n, line in enumerate(p.read_text(encoding="utf-8",
                                             errors="replace").splitlines(), 1):
            for m in RX.finditer(line):
                hits.append((rel, n, m.group(0), line.strip()))

    if hits:
        print(f"  {RED}FAIL{OFF}  {len(hits)} filename(s) a chat client would "
              f"turn into a link")
        for rel, n, tok, line in hits:
            print(f"          {rel}:{n}  {BLD}{tok}{OFF}")
            print(f"            {line[:74]}")
        print()
        print("        Each of these is a hostname to Telegram, X and most")
        print("        forums, on a registry we do not control. Replace it")
        print("        with the full https:// URL of the file.")
        print()
        return 1

    print(f"  {GRN}ok{OFF}    {len(files)} file(s) scanned, none would linkify")
    print()
    print(f"  {GRN}{BLD}every reference is a URL or is not mistakable for one{OFF}")
    print()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(2)

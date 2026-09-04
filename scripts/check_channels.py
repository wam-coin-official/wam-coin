#!/usr/bin/env python3
"""Does the canonical channel list actually name everything that is ours?

    python3 scripts/check_channels.py
    python3 scripts/check_channels.py --offline    # skip the reachability pass

WHY THIS EXISTS

CHANNELS.txt has one job: tell a reader which accounts and hosts are ours,
so that everything else claiming to be WAM can be dismissed. A channel that
is ours and missing from the file does not merely go unlisted -- the file
says "There are no others", so the omission actively brands our own
property an impostor's, and hands anyone who wants to discredit it a
quotation from our own repository.

That has now happened twice.

  Revision 2, 21 August   the explorer, the pool and the Electrum server
                          were live and unlisted
  Revision 3, 4 September the BitcoinTalk announcement thread, up since
                          14 August -- three days after revision 1 -- and
                          the contact address published in SECURITY.md

Revision 2's own note explains the failure exactly, and it happened again a
fortnight later, because the fix was a person remembering and the person did
not. This is the check that does the remembering.

WHAT IT ENFORCES

  1. The two copies -- CHANNELS.txt and site/CHANNELS.txt -- are identical.
     They drifted for a fortnight: the repository root sat at revision 1
     while the site served revision 2, so "the canonical list" named two
     different sets of channels depending on where you read it.

  2. Every URL and address the project publishes about ITSELF, anywhere in
     the documentation, appears in the list. This is the direction that
     catches the real bug: something becomes ours, gets written about, and
     never reaches the file.

  3. Every listed channel resolves. A dead entry in an anti-impersonation
     list is worse than no entry, because a squatter can take the name.

WHAT IT CANNOT CATCH, SAID PLAINLY

It would NOT have caught the BitcoinTalk omission it was written for.

The thread URL appeared nowhere in this repository -- that is precisely why
nobody noticed it for three weeks -- and rule 2 can only compare the list
against what the repository already says somewhere else. A channel that
exists solely in the founder's browser is invisible to any script.

So this catches the case where a channel is written about but unlisted (the
explorer, the pool and the Electrum server, August 21), and the case where
the two copies drift (which had already happened, silently, for a
fortnight). The remaining case -- a channel created and never written down
at all -- has no automated answer, and pretending otherwise would be worse
than the gap. The answer to that one is a habit: a channel is not created
until it is in this file.

Exit 0 all good, 1 something is wrong, 2 the check could not run.
"""

import argparse
import pathlib
import re
import socket
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CANON = ROOT / "CHANNELS.txt"
MIRROR = ROOT / "site" / "CHANNELS.txt"

GRN, RED, YLW, BLD, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[0m"

# Where we talk about ourselves. Scanning the whole tree would drown the
# check in third-party URLs quoted in build notes and integration docs.
SOURCES = [
    "README.md", "SECURITY.md", "WHITEPAPER.md", "CONTRIBUTING.md",
    "docs/START_HERE.md", "docs/START_HERE_AR.md", "docs/LISTING_PACKAGE.md",
    "docs/POOL_OPERATOR.md", "site/index.html",
    "posts/launch.txt",
]
SOURCES += [str(p.relative_to(ROOT)) for p in (ROOT / "posts").rglob("*.txt")
            if p.name != "launch.txt"]

# Hosts and handles that are ours. A URL is "ours" if it sits on one of
# these, which is what makes the omission direction checkable at all.
OURS = re.compile(
    r"""(?xi)
    (?: https?://(?:[a-z0-9-]+\.)*wamcoin\.org [^\s"'<>)\]]*
      | https?://(?:www\.)?github\.com/wam-coin-official [^\s"'<>)\]]*
      | https?://t\.me/wam_coin[^\s"'<>)\]]*
      | https?://(?:www\.)?x\.com/WAMCoinCore[^\s"'<>)\]]*
      | https?://discord\.gg/[A-Za-z0-9]+
      | https?://bitcointalk\.org/index\.php\?topic=\d+[^\s"'<>)\]]*
      | [A-Za-z0-9._%+-]+@proton\.me
    )
    """)

# Trailing punctuation that belongs to the sentence, not the URL.
TRIM = ".,;:)]}>\"'`*"


def identity(u):
    """Reduce a URL to the CHANNEL it belongs to, not the page it points at.

    A channel is an account, a host or a thread -- something that can be
    impersonated and therefore has to be listed. Every path underneath one
    is the same channel:

        github.com/wam-coin-official/wam-coin/releases/tag/v0.1.6
        github.com/wam-coin-official/wam-coin/blob/main/SECURITY.md
        github.com/wam-coin-official/wam-coin.git
                                    -> github.com/wam-coin-official

        wamcoin.org/og-card.png     -> wamcoin.org

    The first version of this compared whole URLs and reported nine
    "missing channels", every one of them a page inside a channel that was
    already listed. A check that cries wolf nine times out of nine gets
    ignored, which is exactly how the omission it exists to catch survived
    three weeks in the first place.
    """
    u = u.strip().rstrip(TRIM)
    low = u.lower()
    if "@" in low and "://" not in low:
        return low
    low = re.sub(r"^https?://", "", low)
    low = re.sub(r"^www\.", "", low)

    m = re.match(r"bitcointalk\.org/index\.php\?topic=(\d+)", low)
    if m:
        return f"bitcointalk.org/topic/{m.group(1)}"
    m = re.match(r"github\.com/([a-z0-9-]+)", low)
    if m:
        return f"github.com/{m.group(1)}"
    m = re.match(r"(t\.me|x\.com|discord\.gg)/([a-z0-9_-]+)", low)
    if m:
        return f"{m.group(1)}/{m.group(2)}"
    # Everything else is identified by its host: one host, one channel.
    return low.split("/")[0]


def find(text):
    """{channel identity: one URL that was written for it}"""
    out = {}
    for m in OURS.finditer(text):
        raw = m.group(0).rstrip(TRIM)
        out.setdefault(identity(raw), raw)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline", action="store_true",
                    help="skip the reachability pass")
    args = ap.parse_args()

    print()
    print(f"{BLD}does the canonical list name everything that is ours?{OFF}")

    if not CANON.exists():
        print(f"  {RED}FAIL{OFF}  {CANON} is missing")
        return 2
    if not MIRROR.exists():
        print(f"  {RED}FAIL{OFF}  {MIRROR} is missing")
        return 2

    canon_text = CANON.read_text(encoding="utf-8")
    bad = 0

    # ---- 1. one list, not two ---------------------------------------
    if canon_text != MIRROR.read_text(encoding="utf-8"):
        print(f"  {RED}FAIL{OFF}  the two copies of the canonical list differ")
        print("        CHANNELS.txt and site/CHANNELS.txt must be identical.")
        print("        They drifted once already: the root sat at revision 1")
        print("        while the site served revision 2.")
        print("        Fix:  cp CHANNELS.txt site/CHANNELS.txt")
        bad += 1
    else:
        print(f"  {GRN}ok{OFF}    both copies of the list are identical")

    listed = find(canon_text)
    print(f"  {GRN}ok{OFF}    {len(listed)} channels listed")

    # ---- 2. nothing of ours is missing from it ----------------------
    missing = {}
    scanned = 0
    for rel in dict.fromkeys(SOURCES):
        p = ROOT / rel
        if not p.exists():
            continue
        scanned += 1
        for u, raw in find(p.read_text(encoding="utf-8", errors="replace")).items():
            if u not in listed:
                missing.setdefault(raw, []).append(rel)

    if missing:
        print(f"  {RED}FAIL{OFF}  {len(missing)} channel(s) of ours are not in "
              f"the list")
        print("        The list says \"There are no others\", so anything")
        print("        missing is branded an impostor's by our own file.")
        for u, where in sorted(missing.items()):
            print(f"          {u}")
            print(f"            published in: {', '.join(sorted(set(where)))}")
        bad += 1
    else:
        print(f"  {GRN}ok{OFF}    nothing of ours is published outside the list "
              f"({scanned} documents scanned)")

    # ---- 3. every listed channel still answers ----------------------
    if args.offline:
        print(f"  {YLW}skipped{OFF}  reachability (--offline)")
    else:
        dead = []
        # Fetch what the file actually WROTE, never the normalised form.
        # The first version fetched the lowercased identity and reported
        # wamcoin.org/CHANNELS.txt dead: the host is case-sensitive, the
        # file exists, and `channels.txt` does not. The check invented a
        # 404 for a file it was itself sitting next to.
        for u, url in sorted(listed.items()):
            if "@" in u and "/" not in u:
                continue                      # an address, nothing to fetch
            if not url.lower().startswith("http"):
                url = "https://" + url
            req = urllib.request.Request(url, method="GET",
                                         headers={"User-Agent": "wam-channel-check"})
            try:
                with urllib.request.urlopen(req, timeout=25) as r:
                    if r.status >= 400:
                        dead.append((u, f"HTTP {r.status}"))
            except urllib.error.HTTPError as e:
                # 403 is Cloudflare or a forum refusing a bare client, not a
                # dead channel. Only 404 and 410 mean the thing is gone.
                if e.code in (404, 410):
                    dead.append((u, f"HTTP {e.code}"))
            except (urllib.error.URLError, socket.timeout, OSError) as e:
                dead.append((u, str(getattr(e, "reason", e))[:60]))

        if dead:
            print(f"  {RED}FAIL{OFF}  {len(dead)} listed channel(s) do not answer")
            print("        A dead entry is worse than no entry: the name is")
            print("        free for somebody else to take.")
            for u, why in dead:
                print(f"          {u}  --  {why}")
            bad += 1
        else:
            print(f"  {GRN}ok{OFF}    every listed channel answers")

    print()
    if bad:
        print(f"  {RED}{BLD}the canonical list is not canonical{OFF}")
        print()
        return 1
    print(f"  {GRN}{BLD}the list names everything that is ours, and nothing "
          f"dead{OFF}")
    print()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(2)

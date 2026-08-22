#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_first_impression.py -- what a stranger sees before they trust us
# ===========================================================================
#
#      python3 scripts/check_first_impression.py
#
#  WHY THIS EXISTS
#
#  On 2026-08-22 a Bisq maintainer read a submission for this coin and
#  replied:
#
#      "I do not see any project related to WAM but an existing coin."
#
#  The links were in the pull request. The project was real, the chain was
#  running, five venues had submissions open. But the GitHub repository had
#  an empty homepage field, no topics at all, and a description that read
#  "a digital currency ecosystem designed for economic liquidity and global
#  trading" -- a sentence containing not one term anybody searches for. The
#  website had no preview card, so every link shared anywhere rendered as a
#  bare URL. And the web search for the project's own name returned an
#  unrelated BEP-20 gaming token that owns the ticker.
#
#  None of that was found by a check. It was found because the founder asked
#  the same question twice.
#
#  The lesson is not "look more carefully next time". It is that how a
#  project appears to someone who has never heard of it is a property of the
#  project, and properties get checked. Five submissions had already gone out
#  to five venues before anyone looked at the front page they pointed at.
#
#  WHAT IS CHECKED
#
#    the repository        description carries terms a person would search
#                          for, homepage points at the site, topics exist
#    the website           title, description, canonical, and the Open Graph
#                          and Twitter tags without which a shared link is a
#                          bare URL with no title, no summary and no mark
#    the published links   every URL the site and CHANNELS.txt advertise
#                          actually resolves, because a dead link on the page
#                          that asks for trust costs more than a missing one
#
#  This needs no credentials: everything here is what an outsider can see.
# ===========================================================================

import argparse
import json
import re
import sys
import urllib.error
import urllib.request

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"
_fails = []

# Terms someone actually types when looking for a coin like this. The repo
# description existed and contained none of them, which is why it was
# invisible: GitHub search matches the description.
SEARCHABLE = ["randomx", "proof of work", "proof-of-work", "bitcoin core",
              "cpu", "mining", "mineable", "blockchain", "cryptocurrency"]


def ok(m):   print(f"  {GRN}ok{OFF}    {m}")
def bad(m):  print(f"  {RED}FAIL{OFF}  {m}"); _fails.append(m)
def warn(m): print(f"  {YEL}!!{OFF}    {m}")
def head(m): print(f"\n{BLD}{m}{OFF}")


def get(url, timeout=25, as_json=False):
    req = urllib.request.Request(url, headers={"User-Agent": "wam-first-impression"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    return json.loads(raw) if as_json else raw.decode("utf-8", "replace")


def check_repo(repo):
    head(f"the repository, as GitHub shows it: {repo}")
    try:
        d = get(f"https://api.github.com/repos/{repo}", as_json=True)
    except Exception as e:
        bad(f"cannot read the repository: {e}")
        return

    desc = (d.get("description") or "").strip()
    if not desc:
        bad("no description -- the repository says nothing about itself")
    else:
        hits = [t for t in SEARCHABLE if t in desc.lower()]
        if not hits:
            bad(f"the description contains no term anyone would search for. "
                f"GitHub search matches this field, so the project is invisible "
                f"to anyone looking for what it is: {desc[:90]!r}")
        else:
            ok(f"description carries: {', '.join(sorted(set(hits))[:4])}")

    home = (d.get("homepage") or "").strip()
    if not home:
        bad("the homepage field is empty -- the repository does not link to the "
            "site, and that field is the first thing a reviewer follows")
    else:
        ok(f"homepage: {home}")

    topics = d.get("topics") or []
    if not topics:
        bad("no topics -- topics are how GitHub is browsed, and with none the "
            "project appears in no list at all")
    elif len(topics) < 3:
        warn(f"only {len(topics)} topic(s): {', '.join(topics)}")
    else:
        ok(f"{len(topics)} topics: {', '.join(topics[:6])}")


def check_site(url):
    head(f"the website, as a link preview renders it: {url}")
    try:
        html = get(url)
    except Exception as e:
        bad(f"{url} did not answer: {e}")
        return None

    def meta(pattern):
        m = re.search(pattern, html, re.I)
        return m.group(1).strip() if m else None

    title = meta(r"<title>([^<]+)</title>")
    ok(f"title: {title}") if title else bad("no <title>")

    desc = meta(r'<meta\s+name=["\']description["\']\s+content=["\']([^"\']+)')
    ok("meta description present") if desc else bad("no meta description")

    # Without these a link posted to X, Discord, Telegram or a forum is a bare
    # URL: no title, no summary, no image. For a project asking strangers to
    # take it seriously that is a real cost, and it is four lines of HTML.
    need = {
        "og:title": r'property=["\']og:title["\']',
        "og:description": r'property=["\']og:description["\']',
        "og:image": r'property=["\']og:image["\']',
        "og:url": r'property=["\']og:url["\']',
        "twitter:card": r'name=["\']twitter:card["\']',
    }
    missing = [k for k, pat in need.items() if not re.search(pat, html, re.I)]
    if missing:
        bad(f"no preview card: missing {', '.join(missing)}. A link shared "
            f"anywhere renders as a bare URL with no title, summary or mark.")
    else:
        ok("Open Graph and Twitter card tags present")

    if not re.search(r'rel=["\']canonical["\']', html, re.I):
        warn("no canonical link")

    return html


def check_links(url, html):
    head("every link the page advertises")
    urls = sorted(set(re.findall(r'href=["\'](https?://[^"\']+)["\']', html or "")))
    # CHANNELS.txt is the file that claims to say what is ours, so the hosts it
    # names matter as much as the ones the page links.
    try:
        chan = get(url.rstrip("/") + "/CHANNELS.txt")
        urls += re.findall(r"https?://[^\s]+", chan)
    except Exception:
        warn("CHANNELS.txt could not be read")

    seen, checked = set(), 0
    for u in urls:
        u = u.rstrip(".,")
        host = u.split("/")[2] if "://" in u else u
        if host in seen:
            continue
        seen.add(host)
        checked += 1
        try:
            req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=20) as r:
                code = r.status
            ok(f"{host} -> {code}")
        except urllib.error.HTTPError as e:
            # 403/405 from sites that dislike scripts is not a broken link.
            (warn if e.code in (403, 405, 429) else bad)(f"{host} -> HTTP {e.code}")
        except Exception as e:
            bad(f"{host} -> {type(e).__name__}: it is on the page and does not answer")

    if checked == 0:
        bad("no links were checked -- this proves nothing")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="wam-coin-official/wam-coin")
    ap.add_argument("--site", default="https://wamcoin.org")
    args = ap.parse_args()

    check_repo(args.repo)
    html = check_site(args.site)
    if html:
        check_links(args.site, html)

    print()
    if _fails:
        print(f"  {RED}{len(_fails)} thing(s) a stranger would notice{OFF}")
        print("  A maintainer at a listing venue read a submission for this coin\n"
              "  and answered: \"I do not see any project related to WAM.\" The\n"
              "  links were in the pull request. This is what he saw instead.\n")
        return 1
    print(f"  {GRN}the project presents itself as a real one{OFF}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

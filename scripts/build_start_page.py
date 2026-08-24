#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  build_start_page.py -- publish the beginner's guide at a shareable address
# ===========================================================================
#
#      python3 scripts/build_start_page.py
#
#  WHY THIS EXISTS
#
#  The guide written for someone who has never run a node lived only here:
#
#      github.com/wam-coin-official/wam-coin/blob/main/docs/START_HERE_AR.md
#
#  Nobody says that in a conversation. It is long, it looks like a filename,
#  and it asks the reader to be comfortable on GitHub before they have been
#  told what a node is. So it becomes:
#
#      wamcoin.org/start        wamcoin.org/start-ar
#
#  WHY IT IS GENERATED AND NOT WRITTEN
#
#  A second copy of a document is a document that will disagree with the
#  first one. That happened twice today: the site's Arabic footer denied two
#  reviewers weeks after the English half was corrected, and both guides told
#  people to download a release whose binaries had been deleted. Every copy
#  is a chance to forget one.
#
#  So docs/START_HERE.md stays the only source, and the page is built from
#  it. Editing the page means editing the guide.
#
#  WHY NOT curl | bash
#
#  One command would be easier to share than four, and it is not offered.
#  "Download this from the internet and run it immediately without looking"
#  is how machines are taken over, and this project spends its whole site
#  telling people to verify a checksum before they run anything. Making the
#  link short is the part that was actually missing. The command stays safe.
# ===========================================================================

import html
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

PAGES = [
    # source,                    output dir,   lang, dir,   title
    ("docs/START_HERE.md",       "site/start",    "en", "ltr",
     "Start here — WAM Coin"),
    ("docs/START_HERE_AR.md",    "site/start-ar", "ar", "rtl",
     "ابدأ من هنا — WAM Coin"),
]

# The site is one hand-written file with no build step and no dependencies.
# This keeps that promise: the same palette, the same fonts, no CDN, nothing
# loaded from anywhere else.
CSS = """
:root{--bg:#faf9f7;--fg:#1a1a1a;--dim:#5c5a57;--rule:#e3e0db;--code:#f2f0ec;--accent:#8a6d1f}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#0e1211;--fg:#eceae7;--dim:#9a9691;--rule:#242a29;--code:#171d1c;--accent:#c9a94a}}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--fg);margin:0;padding:2.2rem 1.1rem 5rem;
 font:16px/1.72 ui-serif,Georgia,"Times New Roman",serif;-webkit-text-size-adjust:100%}
main{max-width:44rem;margin:0 auto}
h1{font-size:1.85rem;line-height:1.25;margin:0 0 .4rem;letter-spacing:-.01em}
h2{font-size:1.28rem;margin:2.6rem 0 .7rem;padding-top:1.1rem;border-top:1px solid var(--rule)}
h3{font-size:1.06rem;margin:1.8rem 0 .5rem}
p,li{margin:.75rem 0}
a{color:inherit;text-decoration:underline;text-underline-offset:2px;text-decoration-color:var(--accent)}
code{background:var(--code);padding:.12em .38em;border-radius:3px;
 font:13.5px/1.5 ui-monospace,"SFMono-Regular",Menlo,Consolas,monospace;word-break:break-word}
pre{background:var(--code);padding:.95rem 1.05rem;border-radius:6px;overflow-x:auto;
 border:1px solid var(--rule)}
pre code{background:none;padding:0;white-space:pre}
blockquote{margin:1.1rem 0;padding:.1rem 0 .1rem 1rem;border-inline-start:3px solid var(--accent);color:var(--dim)}
table{border-collapse:collapse;width:100%;margin:1.1rem 0;font-size:.94rem;display:block;overflow-x:auto}
th,td{border-bottom:1px solid var(--rule);padding:.5rem .6rem;text-align:start}
th{font-weight:600}
hr{border:0;border-top:1px solid var(--rule);margin:2.2rem 0}
.top{display:flex;gap:1rem;flex-wrap:wrap;font-size:.9rem;color:var(--dim);
 margin-bottom:2rem;padding-bottom:1rem;border-bottom:1px solid var(--rule)}
.foot{margin-top:3.5rem;padding-top:1.2rem;border-top:1px solid var(--rule);
 font-size:.87rem;color:var(--dim)}
[dir=rtl]{font-family:ui-serif,"Noto Naskh Arabic","Amiri",Georgia,serif}
[dir=rtl] pre,[dir=rtl] code{direction:ltr;text-align:left}
"""


def esc(s):
    return html.escape(s, quote=False)


def inline(s):
    """Inline markdown: code, bold, italics, links. Code first, so nothing
    inside a code span is reinterpreted."""
    spans = []

    def stash(m):
        spans.append(f"<code>{esc(m.group(1))}</code>")
        return f"\x00{len(spans)-1}\x00"

    s = re.sub(r"`([^`]+)`", stash, s)
    s = esc(s)
    s = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<em>\1</em>", s)
    return re.sub(r"\x00(\d+)\x00", lambda m: spans[int(m.group(1))], s)


def convert(md):
    out, lines, i = [], md.split("\n"), 0
    while i < len(lines):
        ln = lines[i]

        if ln.startswith("```"):
            i += 1
            buf = []
            while i < len(lines) and not lines[i].startswith("```"):
                buf.append(lines[i]); i += 1
            i += 1
            out.append("<pre><code>" + esc("\n".join(buf)) + "</code></pre>")
            continue

        if re.match(r"^\s*(-{3,}|\*{3,})\s*$", ln):
            out.append("<hr>"); i += 1; continue

        m = re.match(r"^(#{1,4})\s+(.*)$", ln)
        if m:
            lvl = len(m.group(1))
            text = m.group(2).strip()
            slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
            out.append(f'<h{lvl} id="{slug}">{inline(text)}</h{lvl}>')
            i += 1
            continue

        # table: a header row followed by a |---|---| separator
        if ln.strip().startswith("|") and i + 1 < len(lines) \
                and re.match(r"^\s*\|[\s:|-]+\|\s*$", lines[i + 1]):
            def cells(row):
                return [c.strip() for c in row.strip().strip("|").split("|")]
            head = cells(ln)
            i += 2
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(cells(lines[i])); i += 1
            t = ["<table><tr>" + "".join(f"<th>{inline(c)}</th>" for c in head) + "</tr>"]
            for r in rows:
                t.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>")
            out.append("".join(t) + "</table>")
            continue

        if re.match(r"^\s*>", ln):
            buf = []
            while i < len(lines) and re.match(r"^\s*>", lines[i]):
                buf.append(re.sub(r"^\s*>\s?", "", lines[i])); i += 1
            out.append("<blockquote>" + convert("\n".join(buf)) + "</blockquote>")
            continue

        m = re.match(r"^\s*([-*+]|\d+\.)\s+", ln)
        if m:
            ordered = bool(re.match(r"^\s*\d+\.", ln))
            tag = "ol" if ordered else "ul"
            items = []
            while i < len(lines) and re.match(r"^\s*([-*+]|\d+\.)\s+", lines[i]):
                items.append(re.sub(r"^\s*([-*+]|\d+\.)\s+", "", lines[i])); i += 1
            out.append(f"<{tag}>" + "".join(f"<li>{inline(x)}</li>" for x in items) + f"</{tag}>")
            continue

        if not ln.strip():
            i += 1; continue

        buf = []
        while i < len(lines) and lines[i].strip() and not lines[i].startswith(("#", "```", "|", ">")) \
                and not re.match(r"^\s*([-*+]|\d+\.)\s+", lines[i]) \
                and not re.match(r"^\s*(-{3,}|\*{3,})\s*$", lines[i]):
            buf.append(lines[i]); i += 1
        out.append("<p>" + inline(" ".join(buf)) + "</p>")

    return "\n".join(out)


def build(src, outdir, lang, direction, title):
    md = (REPO / src).read_text(encoding="utf-8")

    # Links between the two guides point at .md files on GitHub. On the site
    # they must point at the sibling page, or the Arabic reader is sent back
    # to a repository they were never asked to open.
    md = md.replace("START_HERE_AR.md", "/start-ar/").replace("START_HERE.md", "/start/")

    other = "/start-ar/" if lang == "en" else "/start/"
    other_label = "بالعربية" if lang == "en" else "English"
    home = "wamcoin.org" if lang == "en" else "الصفحة الرئيسية"
    src_label = "source" if lang == "en" else "المصدر"
    note = ("This page is generated from docs/START_HERE.md in the repository. "
            "It is the same text; nothing here is written twice."
            if lang == "en" else
            "هذه الصفحة مولَّدة من docs/START_HERE_AR.md في المستودع. "
            "هي النصّ نفسه — لا شيء مكتوبٌ مرّتين.")

    body = convert(md)
    page = f"""<!doctype html>
<html lang="{lang}" dir="{direction}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<link rel="icon" href="/favicon.png" type="image/png">
<meta name="description" content="{'How to run a WAM Coin node, for someone who has never run one.' if lang == 'en' else 'كيف تُشغّل عقدة WAM، لمن لم يُشغّل عقدةً من قبل.'}">
<link rel="canonical" href="https://wamcoin.org{other.replace('-ar', '') if lang == 'en' else '/start-ar/'}">
<meta property="og:type" content="article">
<meta property="og:site_name" content="WAM Coin">
<meta property="og:title" content="{esc(title)}">
<meta property="og:description" content="{'Run a node in four commands, with the checksum step that most guides skip.' if lang == 'en' else 'شغّل عقدةً بأربعة أوامر، مع خطوة التحقّق التي تتخطّاها أغلب الأدلّة.'}">
<meta property="og:image" content="https://wamcoin.org/og-card.png">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="https://wamcoin.org/og-card.png">
<style>{CSS}</style>
</head>
<body>
<main>
<nav class="top">
  <a href="/">{esc(home)}</a>
  <a href="{other}">{esc(other_label)}</a>
  <a href="https://github.com/wam-coin-official/wam-coin/blob/main/{src}">{esc(src_label)}</a>
</nav>
{body}
<p class="foot">{esc(note)}</p>
</main>
</body>
</html>
"""
    d = REPO / outdir
    d.mkdir(parents=True, exist_ok=True)
    (d / "index.html").write_text(page, encoding="utf-8")
    return len(page)


def main():
    for src, outdir, lang, direction, title in PAGES:
        if not (REPO / src).exists():
            print(f"  missing source: {src}")
            return 1
        n = build(src, outdir, lang, direction, title)
        print(f"  {outdir}/index.html  ({n:,} bytes)  from {src}")
    print("\n  wamcoin.org/start   and   wamcoin.org/start-ar")
    return 0


if __name__ == "__main__":
    sys.exit(main())

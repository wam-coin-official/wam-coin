#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""
md_to_print.py -- turn a Markdown document into a print-ready HTML page.

    python3 scripts/md_to_print.py docs/LEGAL_REVIEW_BRIEF_AR.md out.html --rtl

Built for one purpose: handing a document to somebody who does not use
Markdown -- a lawyer, an auditor, an exchange listing desk. They open the HTML
in any browser and print to PDF. No Pandoc, no LaTeX, no pip install.

`--rtl` switches the page to right-to-left with an Arabic-appropriate font
stack. Tables, code and Latin identifiers stay left-to-right inside it, which
is what mixed Arabic/technical text needs -- an address or a hash reversed by
bidi rendering is worse than useless in a legal document.
"""

from __future__ import annotations

import html
import re
import sys

CSS = """
:root { --ink:#111; --muted:#555; --line:#d8dce0; --accent:#0B7C5C; }
* { box-sizing:border-box; }
body {
  margin:0 auto; max-width:800px; padding:40px 32px 80px;
  color:var(--ink); background:#fff;
  font:15px/1.85 %(font)s;
  %(dir_css)s
}
h1 { font-size:24px; margin:0 0 6px; line-height:1.4; }
h2 { font-size:18px; margin:34px 0 12px; padding-bottom:6px;
     border-bottom:2px solid var(--accent); }
h3 { font-size:15.5px; margin:22px 0 8px; color:var(--accent); }
p, li { margin:8px 0; }
ul, ol { padding-%(start)s:26px; }
hr { border:none; border-top:1px solid var(--line); margin:28px 0; }
strong { font-weight:700; }
blockquote {
  margin:14px 0; padding:10px 16px;
  border-%(start)s:4px solid var(--accent);
  background:#f6f9f8;
}
table { border-collapse:collapse; width:100%%; margin:14px 0; font-size:14px; }
th, td { border:1px solid var(--line); padding:7px 10px; text-align:%(start)s; }
th { background:#f2f5f4; font-weight:700; }
code, .ltr {
  direction:ltr; unicode-bidi:isolate;
  font-family:ui-monospace,Consolas,monospace; font-size:13px;
}
code { background:#f2f5f4; padding:1px 5px; border-radius:3px; }
pre { background:#f6f8f8; border:1px solid var(--line); border-radius:5px;
      padding:12px; overflow-x:auto; direction:ltr; text-align:left; }
pre code { background:none; padding:0; }
.num, td:not(:first-child) { }
@media print {
  body { padding:0; max-width:none; font-size:11.5pt; }
  h2 { page-break-after:avoid; }
  table, blockquote, pre { page-break-inside:avoid; }
  a { text-decoration:none; color:inherit; }
}
"""


def inline(text: str) -> str:
    """Escape, then re-apply the small set of inline marks we support."""
    t = html.escape(text)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", t)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
    return t


def convert(md: str) -> str:
    out: list[str] = []
    lines = md.split("\n")
    i = 0
    in_code = False
    list_kind: str | None = None

    def close_list():
        nonlocal list_kind
        if list_kind:
            out.append(f"</{list_kind}>")
            list_kind = None

    while i < len(lines):
        line = lines[i]

        if line.strip().startswith("```"):
            close_list()
            out.append("</pre>" if in_code else "<pre><code>")
            in_code = not in_code
            i += 1
            continue

        if in_code:
            out.append(html.escape(line))
            i += 1
            continue

        # table
        if line.strip().startswith("|") and i + 1 < len(lines) \
                and re.match(r"^\s*\|[\s\-:|]+\|\s*$", lines[i + 1]):
            close_list()
            header = [c.strip() for c in line.strip().strip("|").split("|")]
            out.append("<table><thead><tr>"
                       + "".join(f"<th>{inline(c)}</th>" for c in header)
                       + "</tr></thead><tbody>")
            i += 2
            while i < len(lines) and lines[i].strip().startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in cells) + "</tr>")
                i += 1
            out.append("</tbody></table>")
            continue

        stripped = line.strip()

        if not stripped:
            close_list()
            i += 1
            continue

        if stripped.startswith("---") and set(stripped) <= {"-"}:
            close_list()
            out.append("<hr>")
            i += 1
            continue

        m = re.match(r"^(#{1,4})\s+(.*)$", stripped)
        if m:
            close_list()
            level = len(m.group(1))
            out.append(f"<h{level}>{inline(m.group(2))}</h{level}>")
            i += 1
            continue

        if stripped.startswith("> "):
            close_list()
            out.append(f"<blockquote>{inline(stripped[2:])}</blockquote>")
            i += 1
            continue

        m = re.match(r"^[-*]\s+(.*)$", stripped)
        if m:
            if list_kind != "ul":
                close_list()
                out.append("<ul>")
                list_kind = "ul"
            out.append(f"<li>{inline(m.group(1))}</li>")
            i += 1
            continue

        m = re.match(r"^(\d+)\.\s+(.*)$", stripped)
        if m:
            if list_kind != "ol":
                close_list()
                out.append("<ol>")
                list_kind = "ol"
            out.append(f"<li>{inline(m.group(2))}</li>")
            i += 1
            continue

        close_list()
        out.append(f"<p>{inline(stripped)}</p>")
        i += 1

    close_list()
    if in_code:
        out.append("</pre>")
    return "\n".join(out)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    src, dst = sys.argv[1], sys.argv[2]
    rtl = "--rtl" in sys.argv

    with open(src, encoding="utf-8") as fh:
        md = fh.read()

    title = "Document"
    for line in md.split("\n"):
        if line.startswith("# "):
            title = line[2:].strip()
            break

    css = CSS % {
        "font": ('"Segoe UI",Tahoma,"Noto Naskh Arabic",Arial,sans-serif' if rtl
                 else 'system-ui,-apple-system,"Segoe UI",Roboto,sans-serif'),
        "dir_css": "direction:rtl; text-align:right;" if rtl else "",
        "start": "right" if rtl else "left",
    }

    page = (
        f'<!DOCTYPE html>\n<html lang="{"ar" if rtl else "en"}" '
        f'dir="{"rtl" if rtl else "ltr"}">\n<head>\n'
        f'<meta charset="utf-8">\n'
        f'<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f"<title>{html.escape(title)}</title>\n<style>{css}</style>\n"
        f"</head>\n<body>\n{convert(md)}\n</body>\n</html>\n"
    )

    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(page)

    print(f"  wrote {dst}  ({len(page):,} bytes)")
    print(f"  open it in a browser, then Print -> Save as PDF")
    return 0


if __name__ == "__main__":
    sys.exit(main())

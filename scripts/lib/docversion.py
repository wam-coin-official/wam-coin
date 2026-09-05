#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  docversion.py -- what counts as "the reader is told to download this"
# ===========================================================================
#
#  Imported by scripts/set_version.py, which rewrites those versions, and by
#  scripts/check_docs_version.py, which audits them.
#
#  WHY IT EXISTS
#
#  set_version.py's own header said it: "These are the same contexts
#  check_docs_version.py checks, deliberately: the writer and the auditor must
#  agree on what counts as an instruction." They were written to agree and
#  then kept separately, which is not agreement, it is coincidence with a
#  deadline.
#
#  On 5 September 2026 set_version.py was changed to discover its documents
#  instead of keeping a list of three, because docs/MINE.md had arrived with
#  nine download commands in it and the list could not see it. The auditor was
#  not changed. So afterwards:
#
#      written but not audited : deploy/systemd/laptop/README.md, docs/MINE.md
#      audited but not written : site/index.html
#
#  -- and site/index.html contains no download instruction at all, while the
#  three pages that do (site/start/, site/start-ar/, site/mine/) were in
#  neither list. The auditor was reading a page that could not fail and
#  skipping every page that could, and it printed
#
#      ok    every documented version is one that exists
#
#  which was true of what it read and meaningless about the site.
#
#  A hand-kept list of files goes stale the moment somebody adds a page. That
#  had already been established twice -- once in set_version.py, once in
#  CHANNELS.txt, where "four accounts" survived into a fifth. This is the
#  third, so the list stops being kept by hand anywhere.
# ===========================================================================

import re
import subprocess

# A version number is only an instruction when the reader is being told to
# fetch that exact thing. Every other mention is prose, and prose about old
# versions is usually the most important prose in the file:
#
#     "a node left on v0.1.4 will reject every valid block on launch day
#      and fork itself off the network"
#
# That sentence must survive every release untouched. An early version of the
# auditor matched every vX.Y.Z and reported it as a dead download link -- a
# check that objects to correct text teaches its reader to skip the output,
# and on 2026-08-19 three faults were live at once behind exactly that habit.
#
# So the contexts are named one by one, here, once. Each is written as the
# text before the version and the text after it, and both the rewriting form
# and the searching form are built from the same pair -- so the writer cannot
# move a version the auditor is not looking at, or the other way round.
VERSION = r"\d+\.\d+\.\d+"

CONTEXTS = [
    (r"releases/download/v", r"/"),      # the URL people curl
    (r"wam-(?:coin|miner)-v", r""),      # the tarball, and the directory they cd into
    (r"\[v", r"\]\("),                   # "the release is [v0.1.5](...)"
]

# (prefix)(version)(suffix) -- so a substitution cannot damage the line.
REWRITE = [re.compile(f"({p})({VERSION})({s})") for p, s in CONTEXTS]

# One alternation, version captured in every branch.
FIND = re.compile("|".join(f"{p}({VERSION}){s}" for p, s in CONTEXTS))

# Markdown is what a person edits; the site pages are what a reader actually
# sees. Both are audited. Only the markdown is rewritten, because the pages
# are regenerated from it by build_pages.py -- editing them directly would be
# overwritten by the next build, which is why that difference is stated here
# rather than left for someone to infer.
DOC_GLOBS = ["*.md"]
PAGE_GLOBS = ["site/*.html", "site/*/*.html"]


# Prose that quotes an old version ON PURPOSE, and must survive every release.
#
# The contexts above are narrow but they cannot read intent. On 5 September
# set_version.py rewrote this line in deploy/systemd/laptop/README.md:
#
#     ExecStart=/home/grgo/wam-v0.1.4/wam-coin-v0.1.4/bin/wamd
#
# into `.../wam-v0.1.4/wam-coin-v0.1.7/bin/wamd` -- a path that has never
# existed and never can. The paragraph above it says "The first version of
# wam-node.service named the release directly", so the whole point of the
# quote is that it names v0.1.4. Worse, it half-rewrote: the outer directory
# does not match `wam-(?:coin|miner)-v` and stayed, so the example became
# incoherent rather than merely wrong, and the next reader has to work out
# which half is a typo.
#
# set_version.py's own header promises exactly this will not happen: "Prose
# that names an old version on purpose ... must survive every release
# unchanged." A regular expression cannot tell an instruction from a
# quotation, so the author says which, in the file, where it can be seen:
#
#     <!-- keep-version -->
#         ExecStart=/home/grgo/wam-v0.1.4/wam-coin-v0.1.4/bin/wamd
#     <!-- /keep-version -->
#
# The auditor honours the same marks, from this same module, or it would
# report a frozen v0.1.4 as a dead download link -- a check objecting to
# correct text, which is how people learn to ignore checks.
#
# It is the same shape as today's other fix: prose about a rule must not be
# able to invoke the rule.
FREEZE_OPEN = re.compile(r"<!--\s*keep-version\s*-->")
FREEZE_CLOSE = re.compile(r"<!--\s*/\s*keep-version\s*-->")


def frozen_lines(text):
    """Indices of lines the author has marked as deliberate history."""
    frozen = set()
    on = False
    for i, line in enumerate(text.splitlines()):
        if FREEZE_OPEN.search(line):
            on = True
            frozen.add(i)
            continue
        if FREEZE_CLOSE.search(line):
            on = False
            frozen.add(i)
            continue
        if on:
            frozen.add(i)
    return frozen


def instructed_versions(text):
    """Every version this text actually tells someone to obtain."""
    skip = frozen_lines(text)
    out = set()
    for i, line in enumerate(text.splitlines()):
        if i in skip:
            continue
        for m in FIND.finditer(line):
            out.update(v for v in m.groups() if v)
    return out


def rewrite(text, version):
    """Move every download instruction to `version`. Returns (text, moved).

    Line by line, because freezing is a property of a line. The substitution
    keeps each match's surroundings and replaces only the number, so it cannot
    damage the line it is editing.
    """
    skip = frozen_lines(text)
    moved = []

    def sub(m):
        old = m.group(2)
        if old == version:
            return m.group(0)
        moved.append(old)
        return m.group(1) + version + m.group(3)

    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if i in skip:
            continue
        for p in REWRITE:
            line = p.sub(sub, line)
        lines[i] = line
    return "".join(lines), moved


def discover(repo, globs):
    """Tracked files matching `globs` that carry a download instruction.

    Discovered rather than listed. `git ls-files` is the question "what is in
    this project", which is the only version of that question that stays true
    after somebody adds a page.
    """
    out = subprocess.run(["git", "ls-files", *globs], cwd=str(repo),
                         capture_output=True, text=True).stdout.split()
    found = []
    for rel in out:
        try:
            text = (repo / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if FIND.search(text):
            found.append(rel)
    return sorted(found)


def documents(repo):
    """The files a release rewrites: markdown carrying a download instruction."""
    return discover(repo, DOC_GLOBS)


def pages(repo):
    """The built pages a reader sees, where one carries a download instruction."""
    return discover(repo, PAGE_GLOBS)

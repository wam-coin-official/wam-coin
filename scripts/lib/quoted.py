# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  quoted.py -- text that mentions a thing is not the thing
# ===========================================================================
#
#  Every check here that matches a marker in text has the same blind spot: it
#  cannot tell use from mention. A file that *documents* a rule contains the
#  words of the rule, and the check that enforces the rule finds them.
#
#  On 5-6 September 2026 this happened three times in one day:
#
#    - release.yml hoists a line beginning `MANDATORY:` to the top of the
#      release notes. The notes it read were a commit message explaining the
#      MANDATORY convention, word-wrapped so that the word began a line. Every
#      channel was told a release that changes nothing was UPDATE REQUIRED.
#
#    - set_version.py rewrote `wam-coin-v0.1.4` inside a quotation whose whole
#      point was that it named the old version, producing a path that has
#      never existed. Its own header promises that cannot happen.
#
#    - a guard written to refuse installing a systemd unit that still passed
#      `-rpcpassword` matched the comment in that unit explaining the flag it
#      no longer passes, and refused to install the fix. That one was written
#      an hour after fixing the other two.
#
#  Patching each site is how it comes back a fourth time somewhere else. The
#  fault is not in those three checks; it is that the project had no way for a
#  writer to say "this text is a quotation". So there is one now, it looks the
#  same everywhere, and every text-scanning check honours it.
#
#  HOW TO USE IT, IN ANY FILE
#
#  The marks are plain words, so they sit inside whatever comment syntax the
#  file already has:
#
#      <!-- wam:quote-begin -->            markdown, HTML
#          curl .../wam-coin-v0.1.4.tar.gz
#      <!-- wam:quote-end -->
#
#      # wam:quote-begin                   shell, python, yaml, systemd
#      #     -rpcuser=t -rpcpassword=t
#      # wam:quote-end
#
#  A line carrying `wam:quote-line` is exempt by itself, for the common case
#  of one sentence:
#
#      Never write Co-Authored-By: Claude in a commit.   # wam:quote-line
#
#  WHAT IT IS NOT
#
#  Not a way to silence a check that is telling the truth. The marks say "this
#  is a quotation", and a reviewer can grep for every one of them in a second:
#
#      git grep -n 'wam:quote-'          wam:quote-line
# ===========================================================================

import re

BEGIN = re.compile(r"wam:quote-begin\b")
END = re.compile(r"wam:quote-end\b")
LINE = re.compile(r"wam:quote-line\b")


def quoted_lines(text):
    """Indices of the lines the author marked as quotation.

    The marks themselves are included, so a check never matches its own
    marker line either. An unclosed region runs to the end of the file --
    deliberately: the alternative is a region that silently stops covering
    what the author meant it to cover.
    """
    out = set()
    inside = False
    for i, line in enumerate(text.splitlines()):
        if BEGIN.search(line):
            inside = True
            out.add(i)
            continue
        if END.search(line):
            inside = False
            out.add(i)
            continue
        if inside or LINE.search(line):
            out.add(i)
    return out


def strip_quoted(text, replacement=""):
    """`text` with every quoted line replaced, keeping the line count.

    Line numbers survive, so a check that reports "line 40" still means line
    40 of the real file. That matters more than it sounds: a check that
    reports the wrong line teaches its reader not to trust the line.

    The trailing newline is preserved deliberately. Without it, a file whose
    LAST line is quoted loses that line entirely -- `"a\\nb\\n"` with b blanked
    becomes `"a\\n"`, which splitlines() reports as one line, not two. Found by
    check_mentions.py on its first run, which is the only reason it is not
    still true.
    """
    skip = quoted_lines(text)
    out = "\n".join(replacement if i in skip else line
                    for i, line in enumerate(text.splitlines()))
    if text.endswith(("\n", "\r")):
        out += "\n"
    return out


def unquoted_lines(text):
    """[(1-based line number, line)] for the lines a check should look at."""
    skip = quoted_lines(text)
    return [(i + 1, line) for i, line in enumerate(text.splitlines())
            if i not in skip]

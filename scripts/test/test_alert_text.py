#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""test_alert_text.py -- no alert may contain something Telegram reads as a link.

    python3 scripts/test/test_alert_text.py

WHY

On 12 September the founder opened the operator chat and found this, in an
alarm this project had sent him:

    ... and the signature is the key in SECURITY.md.

with SECURITY.md rendered as a blue hyperlink. `.md` is Moldova's top-level
domain, so Telegram had decided the filename was a website and turned our own
alert into a link to a stranger's server.

It reached the operator chat, not the public channel, which is the only reason
it cost nothing. The mechanism is not private to that message: the release
announcement quotes the tag body, and the tag for v0.1.8 mentions docs/MINE.md
and docs/ROADMAP.md. Those survived because a path segment in front of the
name stops Telegram's detector -- `scripts/check_release_signed.sh` in the same
alarm was left as plain text. A bare NAME.md has nothing in front of it.

In a project whose entire security advice is "check the signature, do not trust
a link somebody sent you", sending a coin's holders a link to an unrelated
foreign domain from the project's own bot is the wrong mistake to make twice.

WHY THIS IS A TEST AND NOT A FIX AT SEND TIME

wamnotify.send posts plain text with no parse_mode, so there is no <code> to
wrap a filename in. Adding parse_mode=HTML to the alerting path would mean
every alert has to be HTML-escaped, and one unescaped `<` or `&` makes Telegram
refuse the message -- which parks the alarm instead of delivering it. That is a
worse failure than a stray link, in the one system that has to work on the
night.

And rewriting the text as it is sent -- inserting a zero-width space, say --
hides the problem from whoever reads the source and produces messages nobody
can grep for.

So the rule is applied where the words are written: do not write a bare
NAME.TLD in anything a person will be sent. Put a path in front of it, name the
fingerprint instead of the file, or say it in words.
"""

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO / "scripts" / "lib"))
import quoted  # noqa: E402  -- needs the path above

# Suffixes this project actually writes that are also real top-level domains.
# .md is Moldova, .sh Saint Helena, .py Paraguay, .zip a real TLD since 2023,
# .so Somalia, .it Italy, .me Montenegro.
TLD = (r"(?:md|sh|py|zip|so|it|me|io|co|ai|tv|cc|in|is|to|ws|st|re|im|ly"
       r"|pl|ru|cn|de|fr|uk|eu|info|com|net|org)")

# A name Telegram will read as a domain: letters, then a dot, then one of those
# suffixes -- and NOTHING in front of it. A preceding "/" or "." makes it a path
# and Telegram leaves it alone, which is why scripts/check_release_signed.sh
# came through as plain text in the same message.
TOKEN = re.compile(r"(?<![\w/.-])([A-Za-z][\w-]*\." + TLD + r")\b")

# String literals, single or double quoted, on one line.
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"' + "|" + r"'((?:[^'\\\n]|\\.)*)'")

# The files whose strings are sent to a person. Everything else may name a file
# however it likes -- a comment, a usage line and a docstring are read in a
# terminal or an editor, where nothing linkifies anything.
# Named, not globbed -- and the names have to be right.
#
# The first version of this list named two files that do not exist:
#
# wam:quote-begin
#     scripts/wam_alert.sh
#     scripts/reorg_watch.py
# wam:quote-end
#
# They are unit_alert.py and check_reorg.py. The run said "4 sender(s)" and
# nothing questioned the number, including me; audit_repo.sh did, within the
# hour, which is exactly what it is for -- and it is why the count is printed.
#
# The marks above are not decoration. Without them this comment, which exists
# to explain the mistake, re-creates it: audit_repo.sh reads every tracked
# file for paths that are referenced and missing, and a sentence naming a
# missing file is indistinguishable from a reference to one. The same thing
# happened in docs/REHEARSALS.md, where a write-up quoted an attribution
# trailer verbatim and the attribution check went red about the write-up.
SENDERS = [
    "scripts/release_watch.py",
    "scripts/peer_watch.py",
    "scripts/login_watch.py",
    "scripts/unit_alert.py",
    "scripts/check_reorg.py",
    "scripts/daily_report.py",
]


def literals_of(path):
    """Every one-line string literal that reads like a sentence.

    Lines the author marked with wam:quote-line, or inside a wam:quote-begin
    region, are skipped -- through scripts/lib/quoted.py, which is the
    mechanism this project already has for exactly this, and which
    check_mentions.py requires every text-scanning check to honour.

    This test's first run failed on a comment that QUOTED the offending
    sentence while explaining its removal. The first fix for that was a
    private rule of its own: blank every whole-line comment. It worked, and
    it was wrong -- a second way of saying "this is a quotation" is a second
    thing for a reader to know, and check_mentions.py went red within the
    hour to say so.
    """
    text = quoted.strip_quoted(path.read_text(encoding="utf-8",
                                              errors="replace"))
    out = []
    for m in LITERAL.finditer(text):
        lit = m.group(1) if m.group(1) is not None else m.group(2)
        if not lit or len(lit) < 12 or " " not in lit:
            continue
        out.append((text[:m.start()].count("\n") + 1, lit))
    return out


def main():
    checked = 0
    findings = []

    for rel in SENDERS:
        p = REPO / rel
        if not p.exists():
            continue
        checked += 1
        for line, lit in literals_of(p):
            for tok in TOKEN.finditer(lit):
                findings.append((rel, line, tok.group(1), lit))

    print()
    print("\033[1mnothing sent to a person may look like a link\033[0m")

    if checked == 0:
        # Exit 2 is this project's convention for "the check could not run".
        # A pass issued over zero files is the failure this whole suite exists
        # to prevent.
        print("  \033[33mno sender was scanned -- this proves nothing\033[0m")
        print()
        return 2

    if findings:
        for rel, line, tok, lit in findings:
            print(f"  \033[31mFAIL\033[0m  {rel}:{line}")
            print(f"        {tok}  will be a hyperlink in Telegram")
            print(f"        in: {lit[:78]}")
        print()
        print("  Put a path in front of it, give the fingerprint instead of")
        print("  the filename, or say it in words. See the header of this file.")
        print()
        return 1

    print(f"  \033[32mok\033[0m    {checked} sender(s): no bare NAME.TLD in any "
          f"message")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())

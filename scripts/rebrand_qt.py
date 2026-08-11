#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""
Replace Bitcoin's user-visible wording in the Qt GUI with WAM's.

    python3 scripts/rebrand_qt.py --tree build/wam-core [--check]

WHY THIS IS A SCRIPT AND NOT A PATCH SET
----------------------------------------
Everywhere else in this project, upstream is modified through anchored
transformations in patch_upstream.py: one edit, one anchor, one reason. That
works because those edits are surgical.

This is not surgical. There are roughly ninety occurrences of "Bitcoin" in the
GUI's user-visible text, spread across twelve .ui files and a dozen sources,
and every one of them says the same thing for the same reason. Ninety anchors
would be ninety chances to drift out of date with upstream, to guard a change
nobody needs to read individually.

WHAT IT DOES NOT TOUCH
----------------------
Only text a user can read is rewritten:

  * the contents of <string> elements in .ui files
  * the contents of tr("...") and QT_TRANSLATE_NOOP("...", "...")
  * the BIP21 URI scheme, which must not stay "bitcoin:" -- a WAM payment QR
    code that a Bitcoin wallet offers to pay is a way to lose money

Identifiers keep their names. BitcoinUnits, BitcoinGUI, BitcoinAddressValidator
and the rest stay exactly as upstream wrote them, because renaming a class
changes no one's experience and guarantees a painful merge at the next release.
Comments are left alone for the same reason.

The script is idempotent: running it twice changes nothing the second time,
which is what lets the build call it unconditionally.
"""

import argparse
import re
import sys
from pathlib import Path

# Applied in order, inside user-visible strings only. Order matters: the URI
# forms have to be rewritten before the bare word, or "bitcoin://" becomes
# "WAM://" and stops being a scheme at all.
PHRASES = [
    ('bitcoin:BC1', 'wam:wam1'),
    ('bitcoin://', 'wam://'),
    ('bitcoin:', 'wam:'),
    ('the bitcoin network', 'the WAM network'),
    ('the Bitcoin network', 'the WAM network'),
    ('Bitcoin network', 'WAM network'),
    ('bitcoin network', 'WAM network'),
    ('Bitcoin address', 'WAM address'),
    ('bitcoin address', 'WAM address'),
    ('Bitcoin Core', 'WAM Coin'),
    ('spend bitcoins', 'spend WAM'),
    ('bitcoins', 'WAM'),
    ('Bitcoins', 'WAM'),
    ('Bitcoin', 'WAM'),
    # Last, and only ever inside a <string> element or a tr() call, so it can
    # never reach bitcoin.qrc, :/icons/bitcoin, or the BitcoinAmountField class.
    ('bitcoin', 'WAM'),
]

# The BIP21 scheme. Not user-visible text, but changing it is the whole point:
# a receive QR code carrying "bitcoin:wam1..." invites a Bitcoin wallet to try
# to pay it.
SCHEME_EDITS = [
    ('src/qt/guiutil.cpp',
     'uri.scheme() != QString("bitcoin")',
     'uri.scheme() != QString("wam")'),
    ('src/qt/guiutil.cpp',
     'QString ret = QString("bitcoin:%1")',
     'QString ret = QString("wam:%1")'),
    ('src/qt/paymentserver.cpp',
     'const QString BITCOIN_IPC_PREFIX("bitcoin:");',
     'const QString BITCOIN_IPC_PREFIX("wam:");'),
]

# The content class is [^<]*, not .*?, and that is the whole safety argument.
# Qt .ui files contain self-closing <string/> elements. A dot-matches-newline
# pattern treats one of those as an opening tag and then runs to the *next*
# </string>, swallowing every element in between -- which on the first attempt
# rewrote <header>qt/bitcoinamountfield.h</header> into wamamountfield.h and a
# widget named openBitcoinConfButton into openWAMConfButton. The build stopped,
# which was lucky; a rename that still compiled would have been worse.
#
# Forbidding '<' in the content makes crossing an element boundary impossible:
# a self-closing tag simply finds no match.
UI_STRING = re.compile(r'(<string[^>]*>)([^<]*)(</string>)')
TR_CALL = re.compile(r'(\btr\(\s*")((?:[^"\\]|\\.)*)(")')
NOOP_CALL = re.compile(r'(QT_TRANSLATE_NOOP\(\s*"[^"]*"\s*,\s*")((?:[^"\\]|\\.)*)(")')


def rewrite(text: str) -> str:
    for old, new in PHRASES:
        text = text.replace(old, new)
    return text


def process_ui(path: Path) -> int:
    original = path.read_text(encoding='utf-8')
    changed = UI_STRING.sub(lambda m: m.group(1) + rewrite(m.group(2)) + m.group(3), original)
    if changed == original:
        return 0
    path.write_text(changed, encoding='utf-8')
    return sum(1 for _ in re.finditer('WAM', changed)) - sum(1 for _ in re.finditer('WAM', original))


def process_source(path: Path) -> int:
    original = path.read_text(encoding='utf-8')
    changed = original
    for pattern in (TR_CALL, NOOP_CALL):
        changed = pattern.sub(lambda m: m.group(1) + rewrite(m.group(2)) + m.group(3), changed)
    if changed == original:
        return 0
    path.write_text(changed, encoding='utf-8')
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tree', required=True, help='path to the Bitcoin Core checkout')
    ap.add_argument('--check', action='store_true',
                    help='report what is left without changing anything')
    args = ap.parse_args()

    tree = Path(args.tree)
    qt = tree / 'src' / 'qt'
    if not qt.is_dir():
        print(f'error: no src/qt under {tree}', file=sys.stderr)
        return 2

    if args.check:
        stale = []
        for path in sorted(list(qt.glob('forms/*.ui')) + list(qt.glob('*.cpp'))):
            text = path.read_text(encoding='utf-8')
            hits = [m.group(2) for m in UI_STRING.finditer(text)] if path.suffix == '.ui' \
                else [m.group(2) for m in TR_CALL.finditer(text)]
            for hit in hits:
                if re.search(r'[Bb]itcoin', hit):
                    stale.append((path.name, hit[:70]))
        if stale:
            print(f'{len(stale)} user-visible strings still say Bitcoin:')
            for name, hit in stale[:20]:
                print(f'  {name}: {hit}')
            return 1
        print('ok    no user-visible string in the GUI says Bitcoin')
        return 0

    touched = 0

    for path in sorted(qt.glob('forms/*.ui')):
        if process_ui(path):
            touched += 1
            print(f'  ui      {path.name}')

    for path in sorted(list(qt.glob('*.cpp')) + list(qt.glob('*.h'))):
        if process_source(path):
            touched += 1
            print(f'  source  {path.name}')

    for rel, old, new in SCHEME_EDITS:
        path = tree / rel
        if not path.is_file():
            print(f'  warning: {rel} not found', file=sys.stderr)
            continue
        text = path.read_text(encoding='utf-8')
        if new in text:
            continue
        if old not in text:
            print(f'  warning: could not find the URI scheme in {rel}', file=sys.stderr)
            continue
        path.write_text(text.replace(old, new), encoding='utf-8')
        touched += 1
        print(f'  scheme  {rel}')

    print(f'\n{touched} files rewritten' if touched else '\nnothing to do; already rebranded')
    return 0


if __name__ == '__main__':
    sys.exit(main())

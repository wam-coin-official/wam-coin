#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""
Rename the built programs from Bitcoin's names to WAM's.

    python3 scripts/rename_binaries.py --tree build/wam-core [--check]

    bitcoind -> wamd        bitcoin-tx     -> wam-tx       bitcoin-qt -> wam-qt
    bitcoin-cli -> wam-cli  bitcoin-util   -> wam-util
                            bitcoin-wallet -> wam-wallet

  plus  bitcoin.conf -> wam.conf,  ~/.bitcoin -> ~/.wam,  bitcoind.pid -> wamd.pid

WHY THIS IS DELICATE
--------------------
Automake derives a program's variable prefix from its name, so `bitcoind` owns
`bitcoind_SOURCES`, `bitcoind_LDADD` and the rest. Renaming the program without
renaming those leaves automake looking for sources that no target declares.

But the same token is also a *filename*:

    bitcoind_SOURCES = $(bitcoin_daemon_sources) init/bitcoind.cpp
    ^^^^^^^^ rename this                        ^^^^^^^^^^^^^^^^^^ never this

A blind search and replace renames the source file too and the build stops --
if you are lucky. The rule that separates them is position: an automake variable
prefix is at the start of a line, a filename never is. Every rewrite below is
anchored to the start of a line or to an exact, unique string.

This script is idempotent, and `--check` reports what is left without touching
anything.
"""

import argparse
import re
import sys
from pathlib import Path

PROGRAMS = [
    ('bitcoind', 'wamd', 'bitcoind', 'wamd'),
    ('bitcoin-cli', 'wam-cli', 'bitcoin_cli', 'wam_cli'),
    ('bitcoin-tx', 'wam-tx', 'bitcoin_tx', 'wam_tx'),
    ('bitcoin-util', 'wam-util', 'bitcoin_util', 'wam_util'),
    ('bitcoin-wallet', 'wam-wallet', 'bitcoin_wallet', 'wam_wallet'),
]

# (path, old, new). Exact strings, each unique in its file.
EXACT = [
    ('src/Makefile.qt.include', 'bin_PROGRAMS += qt/bitcoin-qt', 'bin_PROGRAMS += qt/wam-qt'),
    ('src/Makefile.qt.include', 'qt/bitcoin-qt$(EXEEXT)', 'qt/wam-qt$(EXEEXT)'),
    ('src/Makefile.qt.include', '$(qt_bitcoin_qt_OBJECTS)', '$(qt_wam_qt_OBJECTS)'),

    ('src/common/args.cpp',
     'const char * const BITCOIN_CONF_FILENAME = "bitcoin.conf";',
     'const char * const BITCOIN_CONF_FILENAME = "wam.conf";'),
    ('src/common/args.cpp', 'return pathRet / ".bitcoin";', 'return pathRet / ".wam";'),

    ('src/init.cpp',
     'static const char* BITCOIN_PID_FILENAME = "bitcoind.pid";',
     'static const char* BITCOIN_PID_FILENAME = "wamd.pid";'),

    # The functional framework writes the node's config file by name, and the
    # node now looks for wam.conf. Miss one of these and the node still starts
    # -- it simply never reads the file, so it never sees `regtest=1` and comes
    # up on MAINNET, inside a test, reaching for seed1.wamcoin.org. The failure
    # surfaces sixty seconds later as "unable to connect to bitcoind", which
    # points at everything except the cause.
    ('test/functional/test_framework/test_node.py',
     'self.bitcoinconf = self.datadir_path / "bitcoin.conf"',
     'self.bitcoinconf = self.datadir_path / "wam.conf"'),
    ('test/functional/test_framework/util.py',
     'write_config(os.path.join(datadir, "bitcoin.conf"), n=n, chain=chain, disable_autoconnect=disable_autoconnect)',
     'write_config(os.path.join(datadir, "wam.conf"), n=n, chain=chain, disable_autoconnect=disable_autoconnect)'),
    ('test/functional/test_framework/util.py',
     'with open(os.path.join(datadir, "bitcoin.conf"), \'a\', encoding=\'utf8\') as f:',
     'with open(os.path.join(datadir, "wam.conf"), \'a\', encoding=\'utf8\') as f:'),
    ('test/functional/test_framework/util.py',
     'if os.path.isfile(os.path.join(datadir, "bitcoin.conf")):',
     'if os.path.isfile(os.path.join(datadir, "wam.conf")):'),
    ('test/functional/test_framework/util.py',
     'with open(os.path.join(datadir, "bitcoin.conf"), \'r\', encoding=\'utf8\') as f:',
     'with open(os.path.join(datadir, "wam.conf"), \'r\', encoding=\'utf8\') as f:'),

    # The functional framework's binary table. The KEY is the filename on disk;
    # the first value is the attribute the tests read (self.options.bitcoind),
    # which must not move or every test that starts a node stops compiling.
    # Getting this backwards on the first attempt renamed the attribute and left
    # the filename alone -- the script's own warning is what caught it.
    ('test/functional/test_framework/test_framework.py',
     '"bitcoind": ("bitcoind", "BITCOIND"),',
     '"wamd": ("bitcoind", "BITCOIND"),'),
    ('test/functional/test_framework/test_framework.py',
     '"bitcoind": ("wamd", "BITCOIND"),',
     '"wamd": ("bitcoind", "BITCOIND"),'),
    ('test/functional/test_framework/test_framework.py',
     '"bitcoin-cli": ("bitcoincli", "BITCOINCLI"),',
     '"wam-cli": ("bitcoincli", "BITCOINCLI"),'),
    ('test/functional/test_framework/test_framework.py',
     '"bitcoin-util": ("bitcoinutil", "BITCOINUTIL"),',
     '"wam-util": ("bitcoinutil", "BITCOINUTIL"),'),
    ('test/functional/test_framework/test_framework.py',
     '"bitcoin-wallet": ("bitcoinwallet", "BITCOINWALLET"),',
     '"wam-wallet": ("bitcoinwallet", "BITCOINWALLET"),'),
]


def rename_makefile_am(text):
    """bin_PROGRAMS entries and line-start variable prefixes only."""
    for prog_old, prog_new, var_old, var_new in PROGRAMS:
        text = re.sub(rf'^(\s*bin_PROGRAMS\s*\+?=\s*){re.escape(prog_old)}$',
                      rf'\g<1>{prog_new}', text, flags=re.MULTILINE)
        text = re.sub(rf'^{re.escape(var_old)}_', f'{var_new}_', text, flags=re.MULTILINE)
    return text


def rename_qt_include(text):
    return re.sub(r'^qt_bitcoin_qt_', 'qt_wam_qt_', text, flags=re.MULTILINE)


def apply_exact(tree, report):
    touched = 0
    for rel, old, new in EXACT:
        path = tree / rel
        if not path.is_file():
            report(f'  skip    {rel} (not present)')
            continue
        text = path.read_text(encoding='utf-8')
        if new in text:
            continue
        if old not in text:
            report(f'  WARN    {rel}: could not find {old[:50]!r}')
            continue
        path.write_text(text.replace(old, new), encoding='utf-8')
        report(f'  exact   {rel}')
        touched += 1
    return touched


def check(tree, report):
    """Report anything that would still build under Bitcoin's name."""
    problems = []

    am = (tree / 'src' / 'Makefile.am').read_text(encoding='utf-8')
    for prog_old, _new, var_old, _vn in PROGRAMS:
        if re.search(rf'^\s*bin_PROGRAMS\s*\+?=\s*{re.escape(prog_old)}$', am, re.MULTILINE):
            problems.append(f'Makefile.am still builds a program named {prog_old}')
        if re.search(rf'^{re.escape(var_old)}_', am, re.MULTILINE):
            problems.append(f'Makefile.am still declares {var_old}_* variables')

    qt = (tree / 'src' / 'Makefile.qt.include').read_text(encoding='utf-8')
    if 'bin_PROGRAMS += qt/bitcoin-qt' in qt:
        problems.append('Makefile.qt.include still builds qt/bitcoin-qt')

    for rel, old, _new in EXACT:
        path = tree / rel
        if path.is_file() and old in path.read_text(encoding='utf-8'):
            problems.append(f'{rel} still contains {old[:48]}')

    # The one that fails silently: a node that cannot find its config file
    # starts anyway, on the wrong chain.
    for rel in ('test/functional/test_framework/util.py',
                'test/functional/test_framework/test_node.py'):
        path = tree / rel
        if path.is_file() and '"bitcoin.conf"' in path.read_text(encoding='utf-8'):
            problems.append(f'{rel} still writes bitcoin.conf; the node reads wam.conf '
                            'and would start on mainnet inside a test')

    if problems:
        report(f'{len(problems)} things still carry Bitcoin\'s name:')
        for p in problems:
            report(f'  {p}')
        return 1

    report('ok    every built program, the config file and the datadir say WAM')
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tree', required=True)
    ap.add_argument('--check', action='store_true')
    args = ap.parse_args()

    tree = Path(args.tree)
    if not (tree / 'src' / 'Makefile.am').is_file():
        print(f'error: no src/Makefile.am under {tree}', file=sys.stderr)
        return 2

    report = print

    if args.check:
        return check(tree, report)

    touched = 0

    am_path = tree / 'src' / 'Makefile.am'
    before = am_path.read_text(encoding='utf-8')
    after = rename_makefile_am(before)
    if after != before:
        # A source filename must never move. If one did, the count of
        # "bitcoind.cpp" style tokens would drop, so refuse and say so.
        for filename in ('bitcoind.cpp', 'bitcoin-cli.cpp', 'bitcoin-tx.cpp',
                         'bitcoin-util.cpp', 'bitcoin-wallet.cpp', 'bitcoind-res.rc'):
            if before.count(filename) != after.count(filename):
                print(f'error: the rewrite would have moved the source file {filename}. '
                      'Refusing to write.', file=sys.stderr)
                return 1
        am_path.write_text(after, encoding='utf-8')
        report('  am      src/Makefile.am')
        touched += 1

    qt_path = tree / 'src' / 'Makefile.qt.include'
    before = qt_path.read_text(encoding='utf-8')
    after = rename_qt_include(before)
    if after != before:
        if before.count('init/bitcoin-qt.cpp') != after.count('init/bitcoin-qt.cpp'):
            print('error: the rewrite would have moved init/bitcoin-qt.cpp. Refusing.',
                  file=sys.stderr)
            return 1
        qt_path.write_text(after, encoding='utf-8')
        report('  qt      src/Makefile.qt.include')
        touched += 1

    touched += apply_exact(tree, report)

    report(f'\n{touched} files rewritten' if touched else '\nnothing to do; already renamed')
    return 0


if __name__ == '__main__':
    sys.exit(main())

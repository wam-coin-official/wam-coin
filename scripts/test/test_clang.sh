#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  Does our own code compile with a compiler we do not own?
# ===========================================================================
#
#      bash scripts/test/test_clang.sh
#
#  WHY THIS EXISTS
#
#  On 7 September the macOS build failed in our source, not upstream's:
#
#      wam/rpc/wam_rpc.cpp:332: error: type 'const char[1]' cannot be
#          narrowed to 'bool' in initializer list [-Wc++11-narrowing]
#
#  Two RPCResult overloads both accepted four arguments, so "" was a candidate
#  for a bool parameter. clang reports the narrowing; GCC picks the intended
#  overload silently.
#
#  That is why it shipped. Linux is GCC, the Windows cross-build is GCC, and
#  every binary this project has ever produced came from the one compiler that
#  accepts it. Upstream supports clang 16 and later, so anybody building WAM
#  with clang -- on Linux, not only on a Mac -- would have hit it, and we
#  would not have known what they were describing.
#
#  A macOS CI job finds this in about twenty minutes. This finds it in about
#  twenty seconds, on any Linux machine, which is the difference between a
#  check that gets run and one that gets waited for.
#
#  WHAT IT IS NOT
#
#  Not a build. -fsyntax-only parses and type-checks and stops: no objects, no
#  link, no minutes. It catches the front-end disagreements, which is the class
#  that has actually bitten us. A real clang link is the macOS job's business.
#
#  Exit 0 clean, 1 clang rejected something, 2 the check could not run.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
cd "$HERE"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'

CORE="${CORE_DIR:-$HERE/build/wam-core}"

echo
echo "${BLD}our own sources, read by clang${OFF}"

CXX="${CLANGXX:-clang++}"
if ! command -v "$CXX" >/dev/null 2>&1; then
    # 2, not 0. A compiler that is not installed has not approved anything.
    printf '  %s!!%s    %s is not installed, so nothing was checked:\n' "$YLW" "$OFF" "$CXX"
    printf '            sudo apt-get install -y clang\n\n'
    exit 2
fi

if [ ! -d "$CORE/src" ]; then
    printf '  %s!!%s    no patched tree at %s -- run scripts/fetch-upstream.sh\n\n' \
        "$YLW" "$OFF" "$CORE"
    exit 2
fi
if [ ! -f "$CORE/src/config/bitcoin-config.h" ]; then
    printf '  %s!!%s    the tree is not configured, so the headers are incomplete.\n' "$YLW" "$OFF"
    printf '            Run a build once (install.sh --build-only, or\n'
    printf '            scripts/build_windows.sh) and this becomes fast forever.\n\n'
    exit 2
fi

printf '  %s\n\n' "$("$CXX" --version | head -1)"

# The depends include tree, whichever host was built. Its headers -- boost,
# libevent, sqlite -- are what our files include, and they are portable; the
# question here is our syntax, not the target.
DEP_INC=""
for d in "$CORE"/depends/*/include; do
    [ -d "$d" ] && DEP_INC="$DEP_INC -I$d"
done

INCLUDES="-I$CORE/src -I$CORE/src/config -I$CORE/src/univalue/include"
INCLUDES="$INCLUDES -I$CORE/src/secp256k1/include -I$CORE/src/leveldb/include"
INCLUDES="$INCLUDES -I$CORE/src/leveldb/helpers/memenv -I$CORE/src/crc32c/include"
INCLUDES="$INCLUDES $DEP_INC"

# RandomX's own headers.
#
# install.sh passes these to configure as CPPFLAGS=-I<randomx>/src, and without
# them this cannot read the one file in the project that includes randomx.h.
# The first run reported that as "clang rejects and GCC accepts" -- a confident
# accusation about our code, caused by a missing -I in the checker.
for d in "$HERE/build/randomx/src" "$HOME/wam/build/randomx/src"; do
    if [ -d "$d" ]; then
        INCLUDES="$INCLUDES -I$d"
        break
    fi
done

fails=0
checked=0
skipped=0
unreadable=0

# Our files only. Upstream's disagreements with clang are upstream's business
# and would bury ours.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#src/}"
    tu="$CORE/src/$rel"
    [ -f "$tu" ] || { skipped=$((skipped + 1)); continue; }

    out="$("$CXX" -std=c++20 -fsyntax-only -DHAVE_CONFIG_H $INCLUDES "$tu" 2>&1)"
    rc=$?
    checked=$((checked + 1))

    if [ $rc -eq 0 ]; then
        printf '  %sok%s    %s\n' "$GRN" "$OFF" "$rel"
    elif printf '%s' "$out" | grep -q 'file not found'; then
        # Not a finding about our code. A header this check failed to put on
        # the path says nothing about whether clang accepts what we wrote, and
        # calling it a rejection sends the reader to the wrong file.
        printf '  %s!!%s    %s -- a header is missing from this check, not the code\n' \
            "$YLW" "$OFF" "$rel"
        printf '%s\n' "$out" | grep -E 'file not found' | head -2 | sed 's/^/          /'
        unreadable=$((unreadable + 1))
    else
        printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$rel"
        printf '%s\n' "$out" | grep -E 'error' | head -4 | sed 's/^/          /'
        fails=$((fails + 1))
    fi
done <<EOF
$(git ls-files 'src/wam/*.cpp' 'src/wam/**/*.cpp' 2>/dev/null)
EOF

echo
if [ "$checked" -eq 0 ]; then
    printf '  %sno translation unit was read -- this proves nothing%s\n\n' "$RED" "$OFF"
    exit 2
fi
if [ "$fails" -gt 0 ]; then
    printf '  %s%d file(s) clang rejects and GCC accepts%s\n' "$RED" "$fails" "$OFF"
    echo
    echo '  GCC choosing an overload where clang refuses to is not a clang'
    echo '  problem. Upstream supports clang 16 and later, so this fails for'
    echo '  anybody who builds with it -- and it is what the macOS build fails'
    echo '  on.'
    echo
    exit 1
fi
if [ "$unreadable" -gt 0 ]; then
    printf '  %s%d file(s) clang accepts, %d it could not be shown%s\n' \
        "$YLW" "$checked" "$unreadable" "$OFF"
    printf '  A file this check cannot compile has not been approved by it.\n\n'
    exit 2
fi
printf '  %s%d file(s) clang accepts%s' "$GRN" "$checked" "$OFF"
[ "$skipped" -gt 0 ] && printf ' (%d not in the built tree)' "$skipped"
printf '\n\n'
exit 0

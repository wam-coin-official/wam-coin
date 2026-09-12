#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  build.sh -- compile wam-miner
# ===========================================================================
#
#      bash miner/build.sh
#
#  One translation unit, one g++ invocation, one static library. No autotools,
#  no cmake, no package manager. Somebody who has just downloaded the source
#  should be able to read this script in full before running it.
#
#  Environment:
#      RANDOMX_INCLUDE   default ~/wam/build/randomx/src
#      RANDOMX_LIB       default ~/wam/build/randomx/build/librandomx.a
#      CXX               default g++
#      OUT               default miner/wam-miner
#      LDFLAGS           default empty
#      LDLIBS            default -lpthread
#      RUN_SELF_TEST     default 1; set 0 when cross-compiling
#
#  CROSS-COMPILING
#
#  scripts/build_windows.sh drives this script with the mingw compiler to
#  produce wam-miner.exe, which is why LDFLAGS, LDLIBS and RUN_SELF_TEST are
#  knobs rather than constants: Windows needs -lws2_32 for sockets, a static
#  link so the result is one file somebody can double-click, and it cannot run
#  its own self-test on the Linux machine that built it.
#
#  Skipping that self-test is only acceptable because it is not skipped: the
#  platform-build workflow runs --self-test on a real Windows runner, and the
#  SHA-256, byte-order, target and RandomX vectors all have to pass there
#  before the binary is packaged. A cross-built miner whose RandomX disagreed
#  would hash all day and find nothing.
# ===========================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# Look in this repository first, then in ~/wam.
#
# HERE was already computed from the script's own location and then ignored in
# favour of $HOME/wam -- which is correct on exactly one machine, the laptop
# this was written on. Cloned to /opt/wam on a server it failed with "randomx.h
# not found at /root/wam/build/randomx/src", naming a path the operator never
# chose and cannot see the origin of.
#
# fetch-upstream.sh builds RandomX into <repo>/build/randomx, so the repository
# already knows where its own artefacts are. The $HOME fallback stays for
# anyone with an existing tree built the old way.
for base in "$REPO/build/randomx" "$HOME/wam/build/randomx"; do
    if [ -f "$base/src/randomx.h" ]; then
        RANDOMX_DEFAULT_BASE="$base"
        break
    fi
done
RANDOMX_DEFAULT_BASE="${RANDOMX_DEFAULT_BASE:-$REPO/build/randomx}"

RANDOMX_INCLUDE="${RANDOMX_INCLUDE:-$RANDOMX_DEFAULT_BASE/src}"
RANDOMX_LIB="${RANDOMX_LIB:-$RANDOMX_DEFAULT_BASE/build/librandomx.a}"
CXX="${CXX:-g++}"
OUT="${OUT:-$HERE/wam-miner}"
LDFLAGS="${LDFLAGS:-}"
LDLIBS="${LDLIBS:--lpthread}"
RUN_SELF_TEST="${RUN_SELF_TEST:-1}"

# The Windows resource compiler, when we are producing a .exe.
#
# Derived from $CXX rather than asked for separately: whoever sets CXX to
# x86_64-w64-mingw32-g++ has already said what they are building for, and a
# second variable that has to agree with the first is a variable that will one
# day disagree.
WINDRES="${WINDRES:-}"
case "$CXX" in
    *mingw32-g++|*mingw32-c++|*-w64-mingw32*)
        [ -n "$WINDRES" ] || WINDRES="${CXX%-*}-windres" ;;
esac

fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }

echo "=================================================================="
echo " Building wam-miner"
echo "=================================================================="

command -v "$CXX" >/dev/null 2>&1 \
    || fail "no C++ compiler. Install one with:  sudo apt-get install -y g++"
ok "compiler          $($CXX --version | head -1)"

[ -f "$RANDOMX_INCLUDE/randomx.h" ] \
    || fail "randomx.h not found at $RANDOMX_INCLUDE.
     Build RandomX first (scripts/fetch-upstream.sh), or set RANDOMX_INCLUDE."
ok "randomx headers   $RANDOMX_INCLUDE"

[ -f "$RANDOMX_LIB" ] \
    || fail "librandomx.a not found at $RANDOMX_LIB.
     Build RandomX first, or set RANDOMX_LIB."
ok "librandomx        $RANDOMX_LIB"

# The batched hashing entry points are what make a miner fast rather than
# merely correct. Checking for them here turns a wall of template errors into
# one sentence.
grep -q 'randomx_calculate_hash_next' "$RANDOMX_INCLUDE/randomx.h" \
    || fail "this librandomx predates randomx_calculate_hash_next().
     Update RandomX to 1.1.0 or newer."
ok "batched hashing   available"

echo
# ---------------------------------------------------------------------------
#  The Windows version resource
# ---------------------------------------------------------------------------
#
#  Only when building a .exe, and it is not optional there. An executable that
#  states no company, no product and no description is the profile Defender's
#  classifier flagged as Trojan:Win32/Bearfoos.A!ml on the first Windows build
#  of this miner -- see the header of miner/wam-miner.rc. It is also what
#  somebody sees in Task Manager when they wonder what is using their CPU.
RES_OBJ=""
if [ -n "$WINDRES" ]; then
    if command -v "$WINDRES" >/dev/null 2>&1; then
        RES_OBJ="${OUT%.exe}-res.o"
        "$WINDRES" -I"$HERE" "$HERE/wam-miner.rc" -O coff -o "$RES_OBJ" \
            || fail "the version resource did not compile: $HERE/wam-miner.rc"
        ok "version resource  $(basename "$RES_OBJ")"
    else
        # Not fatal, because a miner that mines is worth more than a miner
        # that describes itself. Said out loud, because shipping it anonymous
        # is a choice and not an accident.
        printf '  \033[33m!!\033[0m    %s not found -- the .exe will carry no\n' "$WINDRES"
        printf '        publisher, product name or description, which makes an\n'
        printf '        antivirus warning considerably more likely. Install\n'
        printf '        binutils-mingw-w64-x86-64.\n'
    fi
fi

echo "  compiling..."

# -O3 and -march=native: this is the hot loop of the whole program, and a
# miner is always built on the machine that will run it. Distributors who need
# a portable binary should override with CXXFLAGS='-O3 -mtune=generic'.
: "${CXXFLAGS:=-O3 -march=native}"

# shellcheck disable=SC2086
"$CXX" -std=c++17 $CXXFLAGS $LDFLAGS \
    -I"$RANDOMX_INCLUDE" \
    -I"$HERE/src" \
    "$HERE/src/main.cpp" \
    $RES_OBJ \
    "$RANDOMX_LIB" \
    $LDLIBS \
    -o "$OUT"

[ -f "$OUT" ] || fail "compilation produced no output"

# An `if`, not `[ -n "$RES_OBJ" ] && rm ...`. This script runs under `set -e`,
# where a trailing && list that evaluates false is a failed command and exits
# the shell -- so the shorter form would have aborted every Linux build, which
# never has a resource object, one line before the self-test.
if [ -n "$RES_OBJ" ]; then
    rm -f "$RES_OBJ"
fi
ok "built             $OUT  ($(( $(stat -c%s "$OUT") / 1024 )) KB)"

echo
if [ "$RUN_SELF_TEST" = "1" ]; then
    echo "  self-test..."
    "$OUT" --self-test --no-colour || fail "the self-test failed; do not use this build"
else
    # Said out loud, because "the build passed" and "the binary is correct" are
    # different claims and this is the one place they come apart.
    printf '  \033[33m!!\033[0m    self-test NOT run -- this binary cannot execute here.\n'
    printf '        It must run --self-test on the target platform before it is\n'
    printf '        packaged or published.\n'
fi

echo
echo "=================================================================="
echo " wam-miner is ready."
echo
echo "   $OUT -o stratum+tcp://<pool>:3333 -u <your WAM address>"
echo "=================================================================="

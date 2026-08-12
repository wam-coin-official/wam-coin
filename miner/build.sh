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
echo "  compiling..."

# -O3 and -march=native: this is the hot loop of the whole program, and a
# miner is always built on the machine that will run it. Distributors who need
# a portable binary should override with CXXFLAGS='-O3 -mtune=generic'.
: "${CXXFLAGS:=-O3 -march=native}"

# shellcheck disable=SC2086
"$CXX" -std=c++17 $CXXFLAGS \
    -I"$RANDOMX_INCLUDE" \
    -I"$HERE/src" \
    "$HERE/src/main.cpp" \
    "$RANDOMX_LIB" \
    -lpthread \
    -o "$OUT"

[ -f "$OUT" ] || fail "compilation produced no output"
ok "built             $OUT  ($(( $(stat -c%s "$OUT") / 1024 )) KB)"

echo
echo "  self-test..."
"$OUT" --self-test --no-colour || fail "the self-test failed; do not use this build"

echo
echo "=================================================================="
echo " wam-miner is ready."
echo
echo "   $OUT -o stratum+tcp://<pool>:3333 -u <your WAM address>"
echo "=================================================================="

#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  build_macos.sh -- build the node on macOS, natively
# ===========================================================================
#
#      bash scripts/fetch-upstream.sh          # fetch and patch Core first
#      bash scripts/build_macos.sh
#
#  WHY NATIVE AND NOT CROSS-COMPILED
#
#  Upstream supports cross-compiling for macOS from Linux, and it needs the
#  macOS SDK extracted from Xcode 15, downloaded with an Apple account, under
#  a licence that lets nobody redistribute it. That is a real cost and it was
#  the reason macOS was put behind Windows in docs/ROADMAP.md §7.
#
#  The second reason given there was worse and was wrong: that nobody here has
#  a Mac to test on. GitHub's hosted runners include real macOS machines, free
#  for public repositories, and this repository is public. So the build is
#  native -- Xcode is already there, no SDK is extracted and no licence
#  question arises -- and the same runner can RUN what it built and sync the
#  chain. The test that was called impossible is the cheaper half.
#
#  TWO MACS, NOT ONE
#
#  Every Mac sold since 2020 is arm64 and everything before it is x86_64, and
#  a binary for one does not run on the other. This script builds for whatever
#  it is running on and says which, so the two runners produce two artifacts
#  that are labelled rather than two files with the same name.
#
#  ARCH FOR RANDOMX, WHICH IS NOT THE SAME QUESTION ON ARM
#
#  scripts/fetch-upstream.sh passes ARCH=x86-64 to RandomX, never native,
#  because a release built with native carried 746 AVX-512 instructions and
#  died with SIGILL on a CPU without them.
#
#  ARCH is an x86 option. Passing x86-64 on Apple Silicon is meaningless at
#  best, so this passes it only on an Intel Mac and lets RandomX decide on
#  arm64 -- and never passes native anywhere. The Apple Silicon baseline is a
#  real question that this does not answer: check_isa_baseline.sh now says so
#  out loud instead of reporting an arm64 binary as within an x86-64 baseline.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$HERE"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'

log()  { printf '  %s\n' "$*"; }
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '  %s!!%s    %s\n' "$YLW" "$OFF" "$*"; }
die()  { printf '\n  %sFAIL%s  %s\n\n' "$RED" "$OFF" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "this builds natively and must run on macOS.
          For Windows use scripts/build_windows.sh, which cross-compiles."

MACH="$(uname -m)"          # arm64 or x86_64
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
CORE_DIR="$BUILD_DIR/wam-core"
RANDOMX_DIR="$BUILD_DIR/randomx"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
OUT_DIR="${OUT_DIR:-$HERE/out/macos-$MACH}"

echo
echo "=================================================================="
echo " ${BLD}building the WAM node for macOS${OFF}  ($MACH)"
echo "=================================================================="
echo

for t in cmake autoconf automake libtool pkg-config; do
    command -v "$t" >/dev/null || die "$t is not installed. On macOS:
          brew install automake libtool pkg-config cmake
          (boost, libevent and sqlite come from depends, not brew --
           see the comment above section 2)"
done
ok "build tools present"

[ -d "$CORE_DIR" ] || die "$CORE_DIR is not here. Run scripts/fetch-upstream.sh first."
[ -d "$RANDOMX_DIR" ] || die "$RANDOMX_DIR is not here. Run scripts/fetch-upstream.sh first."
ok "patched Core tree and RandomX source are present"

# ---------------------------------------------------------------------------
printf '\n%s1. librandomx.a%s\n' "$BLD" "$OFF"

RX_BUILD="$RANDOMX_DIR/build"
if [ -f "$RX_BUILD/librandomx.a" ]; then
    ok "already built"
else
    RX_ARGS=(-DCMAKE_BUILD_TYPE=Release)
    if [ "$MACH" = "x86_64" ]; then
        # Never native. See the header.
        RX_ARGS+=(-DARCH=x86-64)
        log "cmake, ARCH=x86-64"
    else
        log "cmake, arm64 (ARCH is an x86 option and is not passed)"
    fi
    cmake -S "$RANDOMX_DIR" -B "$RX_BUILD" "${RX_ARGS[@]}" >/dev/null \
        || die "cmake could not configure RandomX"
    cmake --build "$RX_BUILD" -j"$JOBS" >/dev/null \
        || die "librandomx.a did not build"
fi
[ -f "$RX_BUILD/librandomx.a" ] || die "librandomx.a was not produced"

if [ -x "$RX_BUILD/randomx-tests" ]; then
    "$RX_BUILD/randomx-tests" >/dev/null 2>&1 \
        && ok "librandomx passes RandomX's own reference vectors" \
        || die "librandomx FAILS the reference test vectors on $MACH.
          A node built on this would compute a different proof-of-work from
          every other node and could not stay on the chain. This is the one
          failure here that must never be worked around."
else
    warn "randomx-tests was not built -- the reference vectors were not run"
fi


cd "$CORE_DIR"
[ -f ./configure ] || ./autogen.sh >/dev/null || die "autogen.sh failed"

RANDOMX_CFLAGS="-I$RANDOMX_DIR/src"
RANDOMX_LIBS="$RX_BUILD/librandomx.a"

# depends, not Homebrew.
#
# The first version of this pointed configure at Homebrew's boost, libevent
# and sqlite, and it failed on the macos-14 runner with twenty errors starting
# here:
#
#     boost/multi_index_container.hpp:354  mp11::mp_at_c<index_type_list,N>
#     ./txmempool.h:396: error: use of undeclared identifier 'txiter'
#
# Homebrew installs the NEWEST boost. Bitcoin Core v28 does not build against
# it -- multi_index fails to instantiate, txiter never gets declared, and half
# the header collapses after it. Nothing about that is macOS, or arm64, or
# WAM. It is the same shape as the mingw finding on Windows: a dependency
# version, discovered by building against whatever a package manager happened
# to have that day.
#
# depends is upstream's answer and it is already how the Windows build here
# works: it fetches and builds the versions Core expects -- boost 1.81.0 --
# so the result does not depend on what Homebrew shipped this week. That makes
# the two platforms consistent rather than each carrying its own accident.
#
# No SDK question arises. depends/README.md lists the macOS SDK under "For
# macOS CROSS compilation", which is building for darwin from Linux. This runs
# on macOS, so the system toolchain is the toolchain.
HOST_TRIPLET="$MACH-apple-darwin"
printf '\n%s2. depends for %s%s\n' "$BLD" "$HOST_TRIPLET" "$OFF"
log "boost 1.81, libevent, sqlite3 -- 20 to 60 minutes the first time"

make -C "$CORE_DIR/depends" \
    "HOST=$HOST_TRIPLET" NO_QT=1 NO_ZMQ=1 NO_UPNP=1 NO_NATPMP=1 NO_USDT=1 \
    -j"$JOBS" > "$BUILD_DIR/depends-macos.log" 2>&1 \
    || die "depends failed for $HOST_TRIPLET. The last 30 lines:
$(tail -30 "$BUILD_DIR/depends-macos.log" | sed 's/^/          /')
          Full log: $BUILD_DIR/depends-macos.log"

CONFIG_SITE_PATH="$CORE_DIR/depends/$HOST_TRIPLET/share/config.site"
[ -f "$CONFIG_SITE_PATH" ] || die "depends produced no config.site at $CONFIG_SITE_PATH"
ok "depends built, config.site present"

printf '\n%s3. the node%s\n' "$BLD" "$OFF"
log "configure --host=$HOST_TRIPLET"
CONFIG_SITE="$CONFIG_SITE_PATH" ./configure \
    --prefix=/ \
    --without-gui \
    --disable-zmq \
    --disable-tests-fuzz-binary \
    CPPFLAGS="$RANDOMX_CFLAGS" \
    LIBS="$RANDOMX_LIBS" \
    > "$BUILD_DIR/configure-macos.log" 2>&1 \
    || die "configure failed. The last 30 lines:
$(tail -30 "$BUILD_DIR/configure-macos.log" | sed 's/^/          /')
          Full log: $BUILD_DIR/configure-macos.log
          Core's own: $CORE_DIR/config.log"
ok "configured"

log "compiling with $JOBS jobs"
make -j"$JOBS" > "$BUILD_DIR/make-macos.log" 2>&1 \
    || die "the build failed. The last 40 lines:
$(tail -40 "$BUILD_DIR/make-macos.log" | sed 's/^/          /')
          Full log: $BUILD_DIR/make-macos.log"
ok "compiled"

# ---------------------------------------------------------------------------
printf '\n%s4. the consensus tests, before anything is kept%s\n' "$BLD" "$OFF"

# install.sh refuses to install a Linux binary that fails these. A binary for
# a new platform has more reason to run them, not less: the monetary schedule
# and the 5% treasury rule are the two things a different compiler on a
# different architecture could quietly get wrong, and a node that gets either
# wrong forks itself off the chain at block 1.
if [ -x ./src/test/test_bitcoin ]; then
    ./src/test/test_bitcoin --run_test=wam_monetary_tests,wam_devfee_tests \
        > "$BUILD_DIR/tests-macos.log" 2>&1 \
        || die "the WAM consensus tests FAIL on $MACH. Refusing to keep this
          binary. The last 20 lines:
$(tail -20 "$BUILD_DIR/tests-macos.log" | sed 's/^/          /')"
    ok "wam_monetary_tests and wam_devfee_tests pass on $MACH"
else
    warn "test_bitcoin was not built -- the consensus tests did not run"
fi

# ---------------------------------------------------------------------------
printf '\n%swhat came out%s\n' "$BLD" "$OFF"

mkdir -p "$OUT_DIR"
FOUND=0
for exe in wamd wam-cli wam-tx wam-util wam-wallet; do
    p="src/$exe"
    [ -f "$p" ] || continue
    FMT="$(file -bL "$p")"
    case "$FMT" in
        *Mach-O*)
            cp "$p" "$OUT_DIR/"
            ok "$exe  $(du -h "$p" | cut -f1)  ($FMT)"
            FOUND=$((FOUND + 1)) ;;
        *)
            die "$p is $FMT, not Mach-O" ;;
    esac
done

echo
[ "$FOUND" -gt 0 ] || die "no macOS executable was produced and make reported
          success. Look in $CORE_DIR/src for what was actually built."

echo "=================================================================="
printf ' %s%d macOS (%s) executable(s) in %s%s\n' "$GRN" "$FOUND" "$MACH" "$OUT_DIR" "$OFF"
echo "=================================================================="
echo
echo "  ${BLD}Compiling is not the gate.${OFF} The gate is agreeing with the chain:"
echo "  scripts/test/test_platform_consensus.sh syncs this binary and compares"
echo "  its block hashes with the ones the Linux nodes already have."
echo

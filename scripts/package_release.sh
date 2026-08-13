#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  package_release.sh -- build portable binaries and checksum them
# ===========================================================================
#
#      bash scripts/package_release.sh [--version v0.1.0]
#
#  Produces, under out/release/:
#
#      wam-coin-<version>-x86_64-linux-gnu.tar.gz   node, cli, tools, wallet
#      wam-miner-<version>-x86_64-linux-gnu.tar.gz  the reference miner
#      SHA256SUMS                                   for both
#
#  PORTABILITY IS THE WHOLE POINT
#  ------------------------------
#  The development build uses `-march=native`, which compiles for exactly the
#  CPU doing the building. That is right for a machine that mines for itself
#  and catastrophic for a release: a binary built on a 2024 laptop with AVX-512
#  dies with SIGILL on anything older, and the miner who downloaded it has no
#  idea why. RandomX is built the same way by default (ARCH=native).
#
#  So the release build compiles RandomX and the miner again, from scratch,
#  against the plain x86-64 baseline. Nothing is lost by this: RandomX detects
#  AES, AVX2 and the rest at *runtime* through randomx_get_flags(), so a
#  generic binary still uses every instruction the host actually has.
#
#  WHAT THIS IS NOT
#  ----------------
#  These are not reproducible builds. Two people running this script will get
#  binaries that differ, and the checksums below prove only that a download
#  arrived intact -- not that it corresponds to this source. Reproducibility
#  needs a pinned toolchain (Guix, as Bitcoin Core does), and until that exists
#  the release notes say so rather than implying a guarantee nobody can check.
# ===========================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# Look in this repository first, then in ~/wam.
#
# HERE and REPO are computed on the two lines above and were then ignored in
# favour of $HOME/wam -- correct on exactly one machine, the laptop this was
# written on. Cloned to /opt/wam on the release server it failed with
#
#     error: missing /root/wam/build/wam-core/src/wamd
#
# naming a path the operator never chose. fetch-upstream.sh builds into
# <repo>/build, so the repository already knows where its own tree is. The
# $HOME fallback stays for anyone with a tree built the old way.
#
# Same defect, same fix, as miner/build.sh. A path written from memory of
# where something lives, in a file that could have asked.
for base in "$REPO/build" "$HOME/wam/build"; do
    if [ -d "$base/wam-core" ]; then
        BUILD_BASE="$base"
        break
    fi
done
BUILD_BASE="${BUILD_BASE:-$REPO/build}"

VERSION="${VERSION:-}"
TREE="${TREE:-$BUILD_BASE/wam-core}"
WORK="${WORK:-$BUILD_BASE/release}"
OUT="${OUT:-$REPO/out/release}"
JOBS="${JOBS:-$(nproc)}"
PLATFORM="x86_64-linux-gnu"

# The baseline every x86-64 CPU made since 2003 supports. RandomX picks up
# AES-NI and AVX2 at runtime regardless.
PORTABLE_FLAGS="-O3 -mtune=generic"

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[ -n "$VERSION" ] || VERSION="v0.1.0-$(date -u +%Y%m%d)"

fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

echo "=================================================================="
echo " Packaging WAM Coin $VERSION for $PLATFORM"
echo "=================================================================="

# ---------------------------------------------------------------------------
step "1. the node binaries"

NODE_BINS=(wamd wam-cli wam-tx wam-util wam-wallet)
for b in "${NODE_BINS[@]}"; do
    [ -x "$TREE/src/$b" ] || fail "missing $TREE/src/$b -- run scripts/build.sh first"
done
[ -x "$TREE/src/qt/wam-qt" ] || fail "missing the GUI -- run scripts/build_qt.sh first"
ok "found ${#NODE_BINS[@]} programs and the wallet"

# Bitcoin Core's configure does not add -march, so these are already portable.
# Assert it rather than assume it: a stray CXXFLAGS in someone's environment
# would produce a release that crashes on half the machines that download it.
if grep -qE '^CXXFLAGS.*-march=' "$TREE/config.log" 2>/dev/null; then
    fail "the node was configured with -march=. Reconfigure without it before releasing."
fi
ok "node build carries no -march= flag"

# ---------------------------------------------------------------------------
step "2. RandomX, rebuilt for the baseline"

RX_SRC="${RX_SRC:-$BUILD_BASE/randomx}"
[ -d "$RX_SRC" ] || fail "RandomX sources not found at $RX_SRC"

RX_BUILD="$WORK/randomx"
if [ ! -f "$RX_BUILD/librandomx.a" ]; then
    mkdir -p "$RX_BUILD"
    (
        cd "$RX_BUILD"
        cmake "$RX_SRC" -DARCH=x86-64 -DCMAKE_BUILD_TYPE=Release > /tmp/wam_rx_cmake.log 2>&1 \
            || { tail -20 /tmp/wam_rx_cmake.log; exit 1; }
        make -j"$JOBS" randomx > /tmp/wam_rx_make.log 2>&1 \
            || { tail -20 /tmp/wam_rx_make.log; exit 1; }
    ) || fail "could not build a portable RandomX -- see /tmp/wam_rx_make.log"
fi
[ -f "$RX_BUILD/librandomx.a" ] || fail "the portable RandomX build produced no library"
ok "librandomx.a  ARCH=x86-64, not native"

# ---------------------------------------------------------------------------
step "3. the miner, rebuilt for the baseline"

MINER_OUT="$WORK/wam-miner"
RANDOMX_INCLUDE="$RX_SRC/src" \
RANDOMX_LIB="$RX_BUILD/librandomx.a" \
CXXFLAGS="$PORTABLE_FLAGS" \
OUT="$MINER_OUT" \
    bash "$REPO/miner/build.sh" > /tmp/wam_miner_release.log 2>&1 \
    || { tail -25 /tmp/wam_miner_release.log; fail "the portable miner build failed"; }
ok "wam-miner     built with $PORTABLE_FLAGS"

"$MINER_OUT" --self-test --no-colour > /tmp/wam_miner_selftest.log 2>&1 \
    || { tail -20 /tmp/wam_miner_selftest.log; fail "the release miner fails its own self-test"; }
ok "self-test     passed on the release binary"

# ---------------------------------------------------------------------------
step "4. assembling"

rm -rf "$WORK/stage" && mkdir -p "$WORK/stage"
mkdir -p "$OUT"

NODE_DIR="$WORK/stage/wam-coin-$VERSION/bin"
MINER_DIR="$WORK/stage/wam-miner-$VERSION"
mkdir -p "$NODE_DIR" "$MINER_DIR"

for b in "${NODE_BINS[@]}"; do
    cp "$TREE/src/$b" "$NODE_DIR/"
done
cp "$TREE/src/qt/wam-qt" "$NODE_DIR/"
cp "$MINER_OUT" "$MINER_DIR/"

# Debug symbols are most of the size and none of the use. 339 MB -> ~30 MB.
strip "$NODE_DIR"/* "$MINER_DIR"/wam-miner 2>/dev/null || true
ok "stripped      symbols removed"

for f in COPYING README.md WHITEPAPER.md SECURITY.md; do
    [ -f "$REPO/$f" ] && cp "$REPO/$f" "$WORK/stage/wam-coin-$VERSION/"
done
cp "$REPO/COPYING" "$REPO/miner/README.md" "$MINER_DIR/" 2>/dev/null || true

cat > "$WORK/stage/wam-coin-$VERSION/RELEASE.txt" <<EOF
WAM Coin $VERSION -- $PLATFORM

  bin/wamd         the node
  bin/wam-cli      talk to a running node
  bin/wam-qt       the graphical wallet
  bin/wam-tx       build and inspect raw transactions
  bin/wam-util     miscellaneous utilities
  bin/wam-wallet   wallet maintenance, offline

Start with:   ./bin/wamd -daemon
Then:         ./bin/wam-cli getblockchaininfo

Verify what you downloaded before you run it:

  sha256sum -c SHA256SUMS

These binaries are built for the plain x86-64 baseline and will run on any
64-bit Intel or AMD processor. They are NOT reproducible builds: the checksums
prove your download is intact, not that it was compiled from this source. If
that distinction matters to you -- and for a currency it should -- build it
yourself. The instructions are in README.md and take about twenty minutes.

Source: https://github.com/wam-coin-official/wam-coin
Security: SECURITY.md
EOF

TARBALL_NODE="wam-coin-$VERSION-$PLATFORM.tar.gz"
TARBALL_MINER="wam-miner-$VERSION-$PLATFORM.tar.gz"

tar -czf "$OUT/$TARBALL_NODE"  -C "$WORK/stage" "wam-coin-$VERSION"
tar -czf "$OUT/$TARBALL_MINER" -C "$WORK/stage" "wam-miner-$VERSION"
ok "$TARBALL_NODE  ($(( $(stat -c%s "$OUT/$TARBALL_NODE") / 1024 / 1024 )) MB)"
ok "$TARBALL_MINER  ($(( $(stat -c%s "$OUT/$TARBALL_MINER") / 1024 )) KB)"

# ---------------------------------------------------------------------------
step "5. checksums"

( cd "$OUT" && sha256sum "$TARBALL_NODE" "$TARBALL_MINER" > SHA256SUMS )
cat "$OUT/SHA256SUMS" | sed 's/^/  /'

echo
echo "=================================================================="
echo " Release staged in $OUT"
echo
echo " Publish the two tarballs and SHA256SUMS together. A checksum file"
echo " hosted beside the file it describes proves only that both came from"
echo " the same place; sign it, or post the hashes somewhere else as well."
echo "=================================================================="

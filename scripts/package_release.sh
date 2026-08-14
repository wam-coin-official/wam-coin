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
    [ -x "$TREE/src/$b" ] || fail "missing $TREE/src/$b -- run ./install.sh --build-only first"
done
# The GUI is optional, and its absence is not an error.
#
# install.sh builds --without-gui on purpose. Adding Qt would pull X11,
# fontconfig, freetype, harfbuzz, dbus and thirty more shared libraries into a
# package that was just cut from seventeen dependencies to two -- and a person
# reviewing a testnet on a headless VPS has no use for a window.
#
# Refusing to package because a component nobody asked for is missing is the
# script deciding for the operator. It now packages what exists and says what
# did not.
HAVE_GUI=0
if [ -x "$TREE/src/qt/wam-qt" ]; then
    HAVE_GUI=1
    ok "found ${#NODE_BINS[@]} programs, the wallet, and the GUI"
else
    ok "found ${#NODE_BINS[@]} programs and the wallet"
    printf '  \033[33mnote\033[0m  no GUI in this build (--without-gui). The node, CLI and\n'
    printf '        miner are packaged; scripts/build_qt.sh builds the GUI if wanted.\n'
fi

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
[ "$HAVE_GUI" = "1" ] && cp "$TREE/src/qt/wam-qt" "$NODE_DIR/"
cp "$MINER_OUT" "$MINER_DIR/"

# Debug symbols are most of the size and none of the use. 339 MB -> ~30 MB.
strip "$NODE_DIR"/* "$MINER_DIR"/wam-miner 2>/dev/null || true
ok "stripped      symbols removed"

for f in COPYING README.md WHITEPAPER.md SECURITY.md; do
    [ -f "$REPO/$f" ] && cp "$REPO/$f" "$WORK/stage/wam-coin-$VERSION/"
done
cp "$REPO/COPYING" "$REPO/miner/README.md" "$MINER_DIR/" 2>/dev/null || true

GUI_LINE=""
[ "$HAVE_GUI" = "1" ] && GUI_LINE="
  bin/wam-qt       the graphical wallet"

cat > "$WORK/stage/wam-coin-$VERSION/RELEASE.txt" <<EOF
WAM Coin $VERSION -- $PLATFORM
=====================================================================

RUN A NODE IN FOUR COMMANDS
---------------------------

  1.  Check what you downloaded is what we built:

          sha256sum --ignore-missing -c SHA256SUMS

      --ignore-missing matters: SHA256SUMS lists both packages, and
      without it a person who took only the node is told the miner
      FAILED and, following this instruction, deletes a good file.

      Every line must say OK. If one does not, delete that file and
      download it again -- do not run it.

  2.  Make sure the two libraries are present. On Ubuntu or Debian:

          sudo apt-get install -y libevent-2.1-7t64 libsqlite3-0

      On Ubuntu 22.04 the first is named libevent-2.1-7 instead. That is
      all this needs; there is no third package.

  3.  Start the node on the test network:

          ./bin/wamd -testnet -daemon

      It finds the network by itself through DNS. Give it a minute.

  4.  Ask it how it is doing:

          ./bin/wam-cli -testnet getblockchaininfo
          ./bin/wam-cli -testnet getsupplyinfo

That is a full node. It validates every block for itself and trusts
nobody, including us.


TO MINE
-------

  Download the miner package beside this one, then:

      ./wam-miner -o stratum+tcp://pool.wamcoin.org:3333 \\
                  -u YOUR_WAM_ADDRESS.rig1

  Get an address first:

      ./bin/wam-cli -testnet createwallet mine
      ./bin/wam-cli -testnet getnewaddress

  TESTNET COINS ARE WORTH NOTHING. They do not carry over to mainnet on
  15 September 2026. This is for testing the software, and that is all.


WHAT IS IN HERE
---------------
  bin/wamd         the node
  bin/wam-cli      talk to a running node$GUI_LINE
  bin/wam-tx       build and inspect raw transactions
  bin/wam-util     miscellaneous utilities
  bin/wam-wallet   wallet maintenance, offline

  DEPENDENCIES.txt what this needs installed, and how to check
  WHITEPAPER.md    the design and its limits
  SECURITY.md      how to report a vulnerability


CHECK OUR CLAIMS RATHER THAN BELIEVING THEM
-------------------------------------------

  ./bin/wam-cli -testnet getsupplyinfo     what the chain says about its money
  ./bin/wam-cli -testnet getdevfeeinfo     the 5% treasury and when it ends
  ./bin/wam-cli -testnet getrandomxinfo    the proof-of-work key schedule

  From the source tree, python3 scripts/verify_supply.py replays all 33
  halvings with exact integer arithmetic and asserts the 22,000,000 cap,
  and python3 scripts/patch_upstream.py --list prints every difference
  from Bitcoin Core with the reason for each.


THE FINE PRINT, WHICH IS THE IMPORTANT PART
-------------------------------------------

  These binaries are built for the plain x86-64 baseline and run on any
  64-bit Intel or AMD processor.

  They are NOT reproducible builds. The checksums prove your download
  arrived intact; they do not prove it was compiled from this source.
  If that distinction matters to you -- and for a currency it should --
  build it yourself. README.md has the steps and it takes about twenty
  minutes.

  There has been no third-party security audit.

Source:   https://github.com/wam-coin-official/wam-coin
Website:  https://wamcoin.org
EOF

# ---------------------------------------------------------------------------
# What will this actually need on a machine that is not this one?
#
# A binary copied to a clean Ubuntu box died with
#
#     error while loading shared libraries: libevent_pthreads-2.1.so.7
#
# which a downloader cannot read as "install one package". The build had been
# linking ZMQ -- a feature nothing here uses -- and that alone pulled in twelve
# libraries including the whole of Kerberos.
#
# So the packager now reads its own output and writes the answer into the
# tarball. Anything appearing here that is not libevent or libsqlite3 is a
# dependency that crept back in, and it is visible at package time rather than
# on a stranger's machine.
step "4b. runtime dependencies"

BASE_LIBS='linux-vdso|ld-linux|libc\.so|libm\.so|libgcc_s|libstdc\+\+|libpthread|libdl|librt|libanl|libresolv'
NEEDED="$(ldd "$WORK/stage/wam-coin-$VERSION/bin/wamd" 2>/dev/null \
          | awk '/=>/ {print $1}' | grep -vE "$BASE_LIBS" | sort -u)"

if [ -z "$NEEDED" ]; then
    ok "no dependencies beyond the C library -- this runs anywhere"
else
    printf '  needs, beyond a bare glibc system:\n'
    printf '%s\n' "$NEEDED" | sed 's/^/    /'
    # Anything unexpected is loud. Twelve of these were shipping silently.
    UNEXPECTED="$(printf '%s\n' "$NEEDED" | grep -vE 'libevent|libsqlite3' || true)"
    if [ -n "$UNEXPECTED" ]; then
        printf '\n  \033[33mwarn\033[0m  unexpected dependencies, each one a package the\n'
        printf '        downloader must already have:\n'
        printf '%s\n' "$UNEXPECTED" | sed 's/^/          /'
        printf '        Was a feature enabled by accident?\n'
    fi
fi

# ---------------------------------------------------------------------------
step "4c. will it start on the oldest system we promise?"

# The library *names* above are only half the question. A binary can link
# exactly the right libraries and still refuse to start, because it was
# compiled against a newer libstdc++ or glibc than the target has: the loader
# needs specific symbol versions, not just the file.
#
# This is not hypothetical. The first release was built on 24.04 and required
# GLIBCXX_3.4.32, which is GCC 14. Ubuntu 22.04 tops out at 3.4.30, so it did
# not start there at all -- while the file it shipped with cheerfully claimed
# "Ubuntu 22.04 / 24.04". Nobody noticed because it was only ever run on the
# machine that built it and on a server of the same version.
#
# The floor is glibc 2.35 / GLIBCXX_3.4.30: Ubuntu 22.04 LTS, which is what
# most providers still hand you by default. Measured, not asserted, and a
# build that exceeds it stops here rather than on a stranger's machine.
BASELINE_GLIBC="2.35"
BASELINE_GLIBCXX="3.4.30"

vermax() { tr ' ' '\n' | sed 's/^[A-Z_]*_//' | sort -V | tail -1; }

SYMS="$(objdump -T "$WORK/stage/wam-coin-$VERSION/bin/wamd" 2>/dev/null \
        | grep -oE 'GLIBCXX_[0-9.]+|GLIBC_[0-9.]+' | sort -u)"

REQ_GLIBC="$(printf '%s\n' "$SYMS" | grep '^GLIBC_'   | vermax)"
REQ_GLIBCXX="$(printf '%s\n' "$SYMS" | grep '^GLIBCXX_' | vermax)"
REQ_GLIBC="${REQ_GLIBC:-0}"; REQ_GLIBCXX="${REQ_GLIBCXX:-0}"

# `sort -V | head -1` picking the baseline means the requirement is <= it.
newer_than() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" != "$1" ]; }

PORTABLE=1
if newer_than "$REQ_GLIBC" "$BASELINE_GLIBC"; then
    PORTABLE=0
    printf '  \033[31mfail\033[0m  needs glibc %s; the baseline is %s\n' \
           "$REQ_GLIBC" "$BASELINE_GLIBC"
fi
if newer_than "$REQ_GLIBCXX" "$BASELINE_GLIBCXX"; then
    PORTABLE=0
    printf '  \033[31mfail\033[0m  needs GLIBCXX_%s; the baseline is %s\n' \
           "$REQ_GLIBCXX" "$BASELINE_GLIBCXX"
fi

if [ "$PORTABLE" = "0" ]; then
    printf '\n  This build will not start on Ubuntu 22.04. It is not a flag that\n'
    printf '  can be added -- the compiler on this machine is too new. Build it\n'
    printf '  on 22.04, or let the release workflow do it (it runs there for\n'
    printf '  exactly this reason).\n\n'
    fail "the binary is not portable to the oldest system this release claims"
fi
ok "glibc <= $BASELINE_GLIBC (needs $REQ_GLIBC), GLIBCXX <= $BASELINE_GLIBCXX (needs $REQ_GLIBCXX)"

# The tarball says what it needs, in the file people open first -- and it says
# it from measurement. A hand-written compatibility line is a claim nobody
# rechecks; this one cannot be wrong without the build failing above.
cat > "$WORK/stage/wam-coin-$VERSION/DEPENDENCIES.txt" <<DEPS
WAM Coin $VERSION -- what this needs to run
===========================================

Measured from this exact binary, not assumed:

    glibc     $REQ_GLIBC or newer
    libstdc++  GLIBCXX_$REQ_GLIBCXX or newer  (GCC 12 and up)

That is Ubuntu 22.04 LTS or newer, Debian 12 or newer, and anything of a
similar age. If your system is older than that, build from source -- no flag
on this binary will make it start.

If the node exits with

    error while loading shared libraries: ...

install the shared libraries it asks for:

    sudo apt-get install -y libevent-2.1-7t64 libsqlite3-0

On Ubuntu 22.04 the libevent package is named libevent-2.1-7 instead.

Nothing else is required. This build has ZMQ disabled, which is why it does
not ask for libzmq, libsodium, libpgm, libnorm or Kerberos -- none of which
this project uses.

Verify what your copy actually wants:

    ldd bin/wamd | grep 'not found'

Empty output means the libraries are present. To check the versions too:

    ldd bin/wamd >/dev/null && echo ok

Anything about GLIBCXX or GLIBC there means your system is older than this
build; use a newer one or build from source.
DEPS

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

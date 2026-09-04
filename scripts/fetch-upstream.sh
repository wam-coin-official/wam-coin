#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  fetch-upstream.sh -- pull the pinned Bitcoin Core tree and apply the WAM
#                       transformations
# ===========================================================================
#
#  WAM Coin is a fork, not a rewrite. Roughly 250,000 lines of peer-to-peer
#  networking, script interpretation, UTXO management and wallet code are
#  inherited from Bitcoin Core -- code that has been adversarially reviewed for
#  fifteen years. Retyping it would not make WAM more original, it would make
#  it less safe.
#
#  What this repository owns is the ~2,000 lines that actually make WAM
#  different: the emission schedule, the treasury rule, DarkGravityWave and
#  RandomX. Those live in src/wam/ and are applied on top by
#  scripts/patch_upstream.py.
#
#  The upstream tag is PINNED. Never track a branch: a consensus layer that
#  changes underneath you between two builds is not a consensus layer.
# ===========================================================================

set -euo pipefail

# An interpreter that is actually Python: `python3` on Windows is a
# Microsoft Store stub that runs nothing and exits 49.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPTS_DIR/lib/python.sh"

# --- pinned upstream -------------------------------------------------------
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/bitcoin/bitcoin.git}"
UPSTREAM_TAG="${UPSTREAM_TAG:-v28.1}"

RANDOMX_REPO="${RANDOMX_REPO:-https://github.com/tevador/RandomX.git}"
RANDOMX_TAG="${RANDOMX_TAG:-v1.2.1}"

# --- layout ----------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
CORE_DIR="$BUILD_DIR/wam-core"
RANDOMX_DIR="$BUILD_DIR/randomx"

log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\033[0;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null    || die "git is not installed"
command -v "$PY" >/dev/null || die ""$PY" is not installed"
command -v cmake >/dev/null  || die "cmake is not installed (needed for RandomX)"

mkdir -p "$BUILD_DIR"

# ===========================================================================
log "1/4  RandomX $RANDOMX_TAG"
# ===========================================================================

if [ -d "$RANDOMX_DIR/.git" ]; then
    log "     already cloned; fetching tags"
    git -C "$RANDOMX_DIR" fetch --tags --quiet
else
    git clone --quiet --depth 1 --branch "$RANDOMX_TAG" "$RANDOMX_REPO" "$RANDOMX_DIR"
fi
git -C "$RANDOMX_DIR" checkout --quiet "$RANDOMX_TAG"

# ARCH=x86-64, not native.
#
# This said native, and the node links librandomx.a statically, so the node
# inherited whatever the build machine's CPU could do. On 2026-08-20 that
# produced a published release carrying 746 AVX-512 instructions -- GitHub's
# runner has AVX-512 -- and it died with SIGILL on an AMD EPYC that does not:
#
#     wamd.service: Main process exited, code=dumped, status=4/ILL
#
# Every other shipped program was clean, because only the node links RandomX.
# Anyone downloading that release on a CPU older than the builder's got a node
# that crashed, which on launch day is most of the miners the coin is for.
#
# Nothing is lost by lowering it: RandomX detects AES-NI and the rest at
# RUNTIME and takes the fast path when the CPU has it. ARCH only decides what
# the compiler may assume unconditionally, which for a binary other people run
# must be the baseline.
#
# WAM_RANDOMX_ARCH=native is available for a local build that will never leave
# the machine. Releases must never set it -- scripts/check_isa_baseline.sh
# refuses to package a binary that carries instructions above the baseline,
# so a slip fails loudly instead of being discovered by a stranger's crash.
RANDOMX_ARCH="${WAM_RANDOMX_ARCH:-x86-64}"

if [ ! -f "$RANDOMX_DIR/build/librandomx.a" ]; then
    log "     building librandomx (ARCH=$RANDOMX_ARCH)"
    cmake -S "$RANDOMX_DIR" -B "$RANDOMX_DIR/build" \
          -DCMAKE_BUILD_TYPE=Release -DARCH="$RANDOMX_ARCH" >/dev/null
    cmake --build "$RANDOMX_DIR/build" -j"$(nproc 2>/dev/null || echo 4)" >/dev/null
else
    log "     librandomx.a already built"
fi

[ -f "$RANDOMX_DIR/build/librandomx.a" ] || die "librandomx.a was not produced"

# Verify the library against the reference vector before anything depends on it.
log "     verifying librandomx against the reference test vector"
if [ -f "$RANDOMX_DIR/build/randomx-tests" ]; then
    "$RANDOMX_DIR/build/randomx-tests" >/dev/null && log "     reference tests pass"
else
    warn "randomx-tests binary not found; skipping the reference check"
fi

# ===========================================================================
log "2/4  Bitcoin Core $UPSTREAM_TAG"
# ===========================================================================

if [ -d "$CORE_DIR/.git" ]; then
    CURRENT="$(git -C "$CORE_DIR" describe --tags --exact-match 2>/dev/null || echo none)"
    if [ "$CURRENT" != "$UPSTREAM_TAG" ]; then
        die "$CORE_DIR is checked out at '$CURRENT', not '$UPSTREAM_TAG'.
     A tree that has already been patched must not be re-patched at a different
     tag. Remove it and re-run:
         rm -rf $CORE_DIR"
    fi
    if [ -f "$CORE_DIR/.wam-patched" ]; then
        log "     already fetched and patched at $UPSTREAM_TAG"
        PATCHED=1
    else
        PATCHED=0
    fi
else
    log "     cloning (shallow, ~120 MB)"
    git clone --quiet --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_REPO" "$CORE_DIR"
    PATCHED=0
fi

# Record the exact commit so a build is reproducible from the log alone.
UPSTREAM_COMMIT="$(git -C "$CORE_DIR" rev-parse HEAD)"
log "     upstream commit $UPSTREAM_COMMIT"

# ===========================================================================
log "3/4  Applying the WAM transformations"
# ===========================================================================

if [ "$PATCHED" = "1" ]; then
    log "     tree is already patched; re-running (the patcher is idempotent)"
fi

"$PY" "$REPO_ROOT/scripts/patch_upstream.py" --tree "$CORE_DIR" --repo "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Rename the binaries.
#
# rename_binaries.py has existed, complete and tested, since the first week,
# and was never called from anywhere. The result shipped as far as a live
# server: the node's executable was still `bitcoind`, with `wamd` a symlink
# beside it. Every check passed, because the symlink works.
#
# It is not cosmetic. A WAM node and a Bitcoin node cannot coexist on one
# machine when both install /usr/local/bin/bitcoind, and package_release.sh
# looks for src/wamd, which never existed.
#
# Run here rather than in patch_upstream.py because it rewrites automake
# variable names, which the anchored-transformation model is deliberately not
# built for -- it renames identifiers across a file rather than replacing a
# known string at a known anchor.
log "     renaming binaries to wamd / wam-cli / wam-tx / wam-util / wam-wallet"
"$PY" "$REPO_ROOT/scripts/rename_binaries.py" --tree "$CORE_DIR"

# Verify rather than assume. --check re-reads the tree and fails if any
# upstream name survived, so a partial rename cannot pass silently.
"$PY" "$REPO_ROOT/scripts/rename_binaries.py" --tree "$CORE_DIR" --check

cat > "$CORE_DIR/.wam-patched" <<EOF
upstream_repo=$UPSTREAM_REPO
upstream_tag=$UPSTREAM_TAG
upstream_commit=$UPSTREAM_COMMIT
randomx_tag=$RANDOMX_TAG
patched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# ===========================================================================
log "4/4  Checking the treasury address"
# ===========================================================================

# This said "founder address" and told you to run gen_founder_key.py and
# re-mine the genesis block. Both were true once and neither is now: the
# founder ceremony happened, the mainnet founder address is real, and the
# mainnet genesis is mined. Following those instructions today would discard
# all three. What is still a placeholder is the *treasury*, which the two were
# separated into so that treasury spending could be told from founder
# spending -- and the warning was never updated to notice.
if grep -q "WNg2svm2qApxheBKndKGQ9sRwporvRgRpT" \
        "$CORE_DIR/src/kernel/chainparams.cpp"; then
    warn "The mainnet TREASURY address is still the burn placeholder"
    warn "(hash160 = 20 zero bytes). Every 5% fee this chain collects would be"
    warn "destroyed -- 750,000 WAM across 400,000 blocks."
    warn ""
    warn "  Before a mainnet binary is usable:"
    warn "    1. "$PY" scripts/gen_founder_key.py --network mainnet   (OFFLINE,"
    warn "       and a DIFFERENT key from the founder's)"
    warn "    2. paste it over WAM_TREASURY_ADDRESS_MAINNET in src/wam/chainparams.cpp"
    warn "    3. re-run this script"
    warn ""
    warn "  The genesis block is NOT re-mined for this. Genesis outputs pay the"
    warn "  founder address, and the treasury rule starts at height 1, so the"
    warn "  genesis hash does not depend on it."
    warn ""
    warn "  It must happen before the first mainnet block and not after: the"
    warn "  rule is consensus, so changing it later invalidates every block"
    warn "  already mined under the old address."
    warn ""
    warn "  Testnet and regtest builds are unaffected."
fi

log "done"
log ""
log "  source tree : $CORE_DIR"
log "  librandomx  : $RANDOMX_DIR/build/librandomx.a"
log ""
log "  Next: ./install.sh --build-only, or see docs/BUILD.md"

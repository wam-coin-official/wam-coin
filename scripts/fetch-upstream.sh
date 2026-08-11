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
command -v python3 >/dev/null || die "python3 is not installed"
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

if [ ! -f "$RANDOMX_DIR/build/librandomx.a" ]; then
    log "     building librandomx"
    cmake -S "$RANDOMX_DIR" -B "$RANDOMX_DIR/build" \
          -DCMAKE_BUILD_TYPE=Release -DARCH=native >/dev/null
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

python3 "$REPO_ROOT/scripts/patch_upstream.py" --tree "$CORE_DIR" --repo "$REPO_ROOT"

cat > "$CORE_DIR/.wam-patched" <<EOF
upstream_repo=$UPSTREAM_REPO
upstream_tag=$UPSTREAM_TAG
upstream_commit=$UPSTREAM_COMMIT
randomx_tag=$RANDOMX_TAG
patched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# ===========================================================================
log "4/4  Checking the founder address"
# ===========================================================================

if grep -qE "WNg2svm2qApxheBKndKGQ9sRwporvRgRpT|T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb" \
        "$CORE_DIR/src/kernel/chainparams.cpp"; then
    warn "The founder address is still the burn placeholder (hash160 = 20 zero bytes)."
    warn ""
    warn "  Before this tree can build a usable mainnet binary you must:"
    warn "    1. python3 scripts/gen_founder_key.py --network mainnet   (OFFLINE)"
    warn "    2. paste the address into src/wam/chainparams.cpp"
    warn "    3. python3 genesis/genesis_generator.py --network mainnet \\"
    warn "           --address W... --patch src/wam/chainparams.cpp"
    warn "    4. re-run this script"
    warn ""
    warn "  A regtest build works fine in the meantime."
fi

log "done"
log ""
log "  source tree : $CORE_DIR"
log "  librandomx  : $RANDOMX_DIR/build/librandomx.a"
log ""
log "  Next: ./install.sh --build-only, or see docs/BUILD.md"

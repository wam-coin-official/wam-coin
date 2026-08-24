#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  install_release.sh -- put a published release behind the running services
# ===========================================================================
#
#      sudo bash scripts/install_release.sh 0.1.6 \
#          --root /home/grgo --bin /home/grgo/wam-current-bin \
#          --owner grgo --restart wam-miner,wam-node
#
#  WHY THIS EXISTS
#
#  Upgrading was a sequence somebody remembered: download, untar, move three
#  symlinks, restart. Every step of it has failed at least once on this
#  project.
#
#    - the pool server was mining with a binary compiled in the git checkout
#      on 13 August -- software nobody could download and no checksum
#      described -- because "just build it here" is one command shorter
#    - the founder's node came back on 0.1.3 hours after being upgraded,
#      because the restart replayed a shell command from weeks earlier
#    - a release was deployed once without its checksum being checked at all
#
#  So it is written down, it verifies before it unpacks, and it says what it
#  did. On 15 September this same command upgrades mainnet, and that is not
#  the morning to be recalling the steps.
#
#  WHAT IT WILL NOT DO
#
#  Build anything. What runs on our machines has to be the bytes a stranger
#  downloads, or a bug we see is a bug only we have -- and worse, a bug they
#  see is one we cannot reproduce.
# ===========================================================================

set -euo pipefail

GRN=$'\033[32m'; RED=$'\033[31m'; BLD=$'\033[1m'; OFF=$'\033[0m'

usage() { sed -n '5,40p' "$0"; exit "${1:-0}"; }

V=""; ROOT=""; BIN=""; OWNER=""; RESTART=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --root)    ROOT="${2:?}"; shift 2 ;;
        --bin)     BIN="${2:?}"; shift 2 ;;
        --owner)   OWNER="${2:?}"; shift 2 ;;
        --restart) RESTART="${2:?}"; shift 2 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  V="$1"; shift ;;
    esac
done

[ -n "$V" ] || usage 2
case "$V" in v*) V="${V#v}" ;; esac
ROOT="${ROOT:-/opt}"
BIN="${BIN:-$ROOT/wam-current-bin}"
OWNER="${OWNER:-root}"

BASE="https://github.com/wam-coin-official/wam-coin/releases/download/v${V}"
WORK="$ROOT/wam-v${V}"

printf '\n%sinstalling WAM v%s%s\n' "$BLD" "$V" "$OFF"
mkdir -p "$WORK"
cd "$WORK"

for f in "wam-coin-v${V}-x86_64-linux-gnu.tar.gz" \
         "wam-miner-v${V}-x86_64-linux-gnu.tar.gz" \
         "SHA256SUMS"; do
    if [ -f "$f" ]; then
        printf '  have      %s\n' "$f"
    else
        printf '  fetching  %s\n' "$f"
        curl -fsSL -o "$f" "$BASE/$f"
    fi
done

# Before anything is unpacked, let alone run. --ignore-missing so that a
# SHA256SUMS covering more artifacts than we fetched is not an error, while
# a file we did fetch and that does not match still is.
printf '\n  %schecksums%s\n' "$BLD" "$OFF"
if ! sha256sum -c --ignore-missing SHA256SUMS 2>&1 | sed 's/^/    /'; then
    printf '  %sa checksum did not match -- nothing was installed%s\n\n' "$RED" "$OFF"
    exit 1
fi

tar -xzf "wam-coin-v${V}-x86_64-linux-gnu.tar.gz"
tar -xzf "wam-miner-v${V}-x86_64-linux-gnu.tar.gz"

NODE_DIR="$WORK/wam-coin-v${V}/bin"
MINER_BIN="$WORK/wam-miner-v${V}/wam-miner"
for f in "$NODE_DIR/wamd" "$NODE_DIR/wam-cli" "$MINER_BIN"; do
    [ -x "$f" ] || { printf '  %smissing after unpacking: %s%s\n\n' "$RED" "$f" "$OFF"; exit 1; }
done

printf '\n  %swhat the new binaries say they are%s\n' "$BLD" "$OFF"
"$NODE_DIR/wamd" -version 2>/dev/null | head -1 | sed 's/^/    /'

mkdir -p "$BIN"
ln -sfn "$NODE_DIR/wamd"    "$BIN/wamd"
ln -sfn "$NODE_DIR/wam-cli" "$BIN/wam-cli"
ln -sfn "$MINER_BIN"        "$BIN/wam-miner"
chown -h "$OWNER:$OWNER" "$BIN/wamd" "$BIN/wam-cli" "$BIN/wam-miner" 2>/dev/null || true

printf '\n  %ssymlinks%s\n' "$BLD" "$OFF"
ls -l "$BIN" | tail -n +2 | sed 's/^/    /'

if [ -n "$RESTART" ]; then
    printf '\n  %srestarting%s\n' "$BLD" "$OFF"
    IFS=',' read -r -a units <<< "$RESTART"
    systemctl daemon-reload
    for u in "${units[@]}"; do
        systemctl restart "$u" || printf '    %s%s failed to restart%s\n' "$RED" "$u" "$OFF"
    done
    sleep 8
    for u in "${units[@]}"; do
        printf '    %-22s %s\n' "$u" "$(systemctl is-active "$u")"
    done
fi

printf '\n  %sdone%s -- confirm with: journalctl -u wam-miner -n 20 --no-pager\n\n' \
    "$GRN" "$OFF"

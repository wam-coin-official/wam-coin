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

# Resolved HERE, before the cd below, and not where it is used.
#
# It used to be computed further down, next to the verifier call that needs
# it -- which reads better and is wrong. By then the script has already done
# `cd "$WORK"`, so `dirname "$0"` -- a relative "scripts" when invoked as
# `bash scripts/install_release.sh` -- points at a directory that no longer
# exists from where we are standing:
#
#     install_release.sh: line 102: cd: scripts: No such file or directory
#
# It aborted after downloading the release and before verifying or installing
# anything, on the first machine this script had touched in weeks. A path
# taken from $0 is only meaningful before the first cd, wherever it is read.
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"

printf '\n%sinstalling WAM v%s%s\n' "$BLD" "$V" "$OFF"
mkdir -p "$WORK"
cd "$WORK"

for f in "wam-coin-v${V}-x86_64-linux-gnu.tar.gz" \
         "wam-miner-v${V}-x86_64-linux-gnu.tar.gz" \
         "SHA256SUMS" \
         "SHA256SUMS.asc"; do
    if [ -f "$f" ]; then
        printf '  have      %s\n' "$f"
    else
        printf '  fetching  %s\n' "$f"
        curl -fsSL -o "$f" "$BASE/$f"
    fi
done

# ---------------------------------------------------------------------------
#  The signature, not just the checksums -- and by the same script a stranger
#  runs, not a second implementation of it.
#
#  Until 5 September 2026 this installer checked SHA256SUMS and stopped there.
#  A checksum file fetched from the same host as the binaries proves only that
#  both came from that host: whoever can replace the tarball replaces the list
#  beside it, and the two agree perfectly. It catches a truncated download. It
#  catches nobody.
#
#  This is the script that puts software on the seed nodes and on the pool
#  that will hold miners' money after 15 September. It was performing the
#  weaker check, on the machines where the consequence is largest, while
#  every page this project publishes told strangers to run the stronger one.
#
#  verify_release.sh is called rather than reimplemented. Two verifiers drift:
#  one gets a fix and the other keeps the bug, and the one that keeps it is
#  whichever is read less -- which would be this one. It also carries the
#  fingerprint from SECURITY.md and compares it explicitly, so a substituted
#  SIGNING-KEY.asc changes the fingerprint and the comparison catches it.
# ---------------------------------------------------------------------------
VERIFY="$SELF_DIR/verify_release.sh"
if [ ! -x "$VERIFY" ] && [ ! -f "$VERIFY" ]; then
    printf '  %sverify_release.sh is not beside this script%s\n' "$RED" "$OFF"
    printf '  Nothing was installed. An unverified release is not installable\n'
    printf '  by this path, deliberately.\n\n'
    exit 1
fi

printf '\n  %ssignature and checksums%s\n' "$BLD" "$OFF"

# The status is taken from the verifier, not from the pipeline that indents
# its output. `set -o pipefail` is on above and would carry it, but a check
# whose correctness depends on a line forty lines away is a check waiting to
# be broken by someone tidying up. Captured, then reported, then decided.
vout="$(bash "$VERIFY" "$WORK" 2>&1)"; vrc=$?
printf '%s\n' "$vout" | sed 's/^/    /'
if [ "$vrc" -ne 0 ]; then
    printf '\n  %sthe release did not verify -- nothing was installed%s\n\n' "$RED" "$OFF"
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

# 2>/dev/null used to be here, and it threw away the only sentence that
# mattered. On a clean Ubuntu 24.04 this line exited 127 -- the loader's code
# for "I could not start it" -- printed nothing, and took the whole install
# with it under `set -e`, after the release had downloaded and verified. The
# reason was sitting on stderr:
#
#     wamd: error while loading shared libraries: libevent_pthreads-2.1.so.7
#
# An installer that puts down a binary and never checks it runs has not
# installed anything. So: run it, and if it will not run, say which libraries
# are missing and which packages carry them, rather than an exit code.
if ! ver="$("$NODE_DIR/wamd" -version 2>&1 | head -1)" || \
   printf '%s' "$ver" | grep -q "error while loading shared libraries"; then
    printf '    %s%s%s\n' "$RED" "$ver" "$OFF"
    printf '\n  %sthe binaries are installed but cannot start%s\n' "$RED" "$OFF"
    miss="$(ldd "$NODE_DIR/wamd" 2>/dev/null | grep 'not found' | awk '{print $1}')"
    [ -n "$miss" ] && printf '%s\n' "$miss" | sed 's/^/      missing  /'
    printf '\n  These come from your distribution, not from us:\n\n'
    if command -v apt-get >/dev/null 2>&1; then
        # 24.04 renamed them in the 64-bit time_t transition, and the old
        # names do not exist there. Offer what this machine actually has.
        if apt-cache policy libevent-2.1-7t64 2>/dev/null | grep -q 'Candidate: [0-9]'; then
            printf '      sudo apt install libevent-2.1-7t64 libevent-pthreads-2.1-7t64 libsqlite3-0\n\n'
        else
            printf '      sudo apt install libevent-2.1-7 libevent-pthreads-2.1-7 libsqlite3-0\n\n'
        fi
    else
        printf '      libevent, libevent-pthreads and sqlite, by your package manager s names\n\n'
    fi
    printf '  Then run this script again. Nothing is half-installed: the\n'
    printf '  symlinks below have not been moved.\n\n'
    exit 1
fi
printf '    %s\n' "$ver"

mkdir -p "$BIN"
ln -sfn "$NODE_DIR/wamd"    "$BIN/wamd"
ln -sfn "$NODE_DIR/wam-cli" "$BIN/wam-cli"
ln -sfn "$MINER_BIN"        "$BIN/wam-miner"

# The offline tools go through here too, and did not until 11 September.
#
# Because nothing kept them current, both production seeds were still holding
# COPIES of the v0.1.5 wam-tx, wam-util and wam-wallet from 23 August, in
# /usr/local/bin, four days before mainnet -- while wamd beside them was
# v0.1.7. wam-wallet is the one that matters: it is the tool that opens and
# repairs a wallet file, and reaching for a two-release-old one is how a
# wallet gets damaged by the thing meant to rescue it.
#
# Symlinks rather than copies, for the same reason the other three are: a copy
# is a decision that stops tracking the release the moment it is made.
for t in wam-tx wam-util wam-wallet; do
    [ -f "$NODE_DIR/$t" ] && ln -sfn "$NODE_DIR/$t" "$BIN/$t"
done
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

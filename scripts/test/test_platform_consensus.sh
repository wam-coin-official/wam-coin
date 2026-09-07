#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  Does a node built for a new platform agree with the chain?
# ===========================================================================
#
#      bash scripts/test/test_platform_consensus.sh <dir-with-wamd-and-wam-cli>
#
#  WHY COMPILING IS NOT THE GATE
#
#  A binary that builds cleanly for Windows or macOS has proved that the
#  toolchain works. It has not proved that it computes the same proof-of-work,
#  applies the same monetary schedule, or enforces the 5% treasury rule the
#  same way. A different compiler on a different architecture can get any of
#  those subtly wrong and still link.
#
#  A node that gets one of them wrong does not fail loudly. It forks itself
#  off the chain and keeps running -- its owner mines onto a history nobody
#  else has, and finds out when the coins do not exist anywhere else. That is
#  the outcome this exists to make impossible, and it is worse than shipping
#  no Windows build at all.
#
#  So the gate is: sync from genesis on the real test network, over the real
#  peer-to-peer protocol, and then agree with blocks the Linux nodes have been
#  holding since August. Syncing to the same blocks means every one of them
#  was validated the same way -- a node that accepted something different
#  would be on a different chain by now, and a node that rejected something
#  valid would have stopped.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
KNOWN="$HERE/scripts/test/known_testnet_blocks.txt"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'

ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$*"; }
warn() { printf '  %s!!%s    %s\n' "$YLW" "$OFF" "$*"; }

BIN_DIR="${1:-}"
[ -n "$BIN_DIR" ] || { printf 'usage: %s <dir-with-wamd-and-wam-cli>\n' "${0##*/}" >&2; exit 2; }
[ -d "$BIN_DIR" ] || { printf 'not a directory: %s\n' "$BIN_DIR" >&2; exit 2; }
[ -f "$KNOWN" ]   || { printf 'missing %s\n' "$KNOWN" >&2; exit 2; }

# .exe on a Windows runner, bare everywhere else.
WAMD=""; CLI=""
for c in "$BIN_DIR/wamd" "$BIN_DIR/wamd.exe"; do [ -f "$c" ] && WAMD="$c"; done
for c in "$BIN_DIR/wam-cli" "$BIN_DIR/wam-cli.exe"; do [ -f "$c" ] && CLI="$c"; done
[ -n "$WAMD" ] || { printf 'no wamd in %s\n' "$BIN_DIR" >&2; exit 2; }
[ -n "$CLI" ]  || { printf 'no wam-cli in %s\n' "$BIN_DIR" >&2; exit 2; }

# The highest height the known-blocks file mentions. Syncing past it is what
# the wait is for; there is no reason to sync further than the question needs.
TARGET="$(grep -vE '^\s*#|^\s*$' "$KNOWN" | awk '{print $1}' | sort -n | tail -1)"
TIMEOUT_SEC="${SYNC_TIMEOUT:-1800}"

DATADIR="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wam-plat-$$")"
mkdir -p "$DATADIR"

# wamd.exe is a Windows program and does not understand /c/Users/... .
#
# Under Git Bash or MSYS -- which is the shell on a windows-latest runner and
# on the founder's machine -- mktemp returns a POSIX path, and passing it as
# -datadir= leaves the node to create a directory called "c" inside its own
# working directory and sync into that. It would have looked like a mysterious
# permissions problem, on the one platform this test exists to cover.
#
# cygpath is what MSYS ships for exactly this. The POSIX form is kept for
# mkdir and rm, which are the shell's own business, and only the value handed
# to the node is converted.
DATADIR_NATIVE="$DATADIR"
case "${OSTYPE:-}" in
    msys*|cygwin*|win32*)
        if command -v cygpath >/dev/null 2>&1; then
            DATADIR_NATIVE="$(cygpath -w "$DATADIR")"
        fi
        ;;
esac

# An RPC port of its own, because the default is not free on any machine that
# already runs a node -- which is every machine somebody would test a new
# build on.
#
# The first run of this on Windows died in ten seconds:
#
#     Binding RPC on address 127.0.0.1 port 19554 failed.
#     Unable to bind any endpoint for RPC server
#
# The binary was fine. wslrelay held 19554, forwarding it from the node
# running inside WSL, because WSL2 shares localhost with Windows. Reported as
# it stood, that reads as "the Windows node cannot start" -- a verdict on the
# port, delivered about the build.
#
# /dev/tcp rather than ss or netstat: this has to work identically under Git
# Bash on Windows, on a macOS runner and on Linux, and bash brings its own.
free_port() {
    local p
    for p in $(seq 24554 24600); do
        (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && { exec 3>&- 2>/dev/null; continue; }
        printf '%s\n' "$p"
        return 0
    done
    return 1
}
RPCPORT="$(free_port)" || { printf 'no free port in 24554-24600\n' >&2; exit 2; }

cleanup() {
    "$CLI" -testnet -datadir="$DATADIR_NATIVE" -rpcport="$RPCPORT" stop >/dev/null 2>&1
    sleep 3
    [ -n "${NODE_PID:-}" ] && kill "$NODE_PID" 2>/dev/null
    wait "${NODE_PID:-}" 2>/dev/null
    rm -rf "$DATADIR" 2>/dev/null
}
trap cleanup EXIT

echo
echo "=================================================================="
echo " ${BLD}does this binary agree with the chain?${OFF}"
echo "=================================================================="
echo
printf '  binary   %s\n' "$WAMD"
printf '  platform %s %s\n' "$(uname -s 2>/dev/null || echo unknown)" "$(uname -m 2>/dev/null || echo)"
printf '  target   height %s\n' "$TARGET"
printf '  rpc port %s -- the default is taken on any machine already running a node\n\n' "$RPCPORT"

# -daemon does not exist on Windows, so the node is backgrounded the same way
# on every platform rather than one way here and another there.
#
# The seeds are named explicitly. Leaving it to DNS would make a DNS problem
# look like a consensus problem, and the question being asked is about the
# binary.
"$WAMD" -testnet -datadir="$DATADIR_NATIVE" -rpcport="$RPCPORT" \
        -addnode=169.58.159.165 -addnode=5.223.52.200 \
        -listen=0 -printtoconsole=0 \
        > "$DATADIR/node.out" 2>&1 &
NODE_PID=$!

printf '  syncing'
ELAPSED=0
HEIGHT=0
while [ "$ELAPSED" -lt "$TIMEOUT_SEC" ]; do
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    if ! kill -0 "$NODE_PID" 2>/dev/null; then
        echo
        bad "the node exited on its own after ${ELAPSED}s"
        echo
        tail -25 "$DATADIR/node.out" 2>/dev/null | sed 's/^/          /'
            tail -25 "$DATADIR"/testnet*/debug.log 2>/dev/null | sed 's/^/          /'
        exit 1
    fi
    H="$("$CLI" -testnet -datadir="$DATADIR_NATIVE" -rpcport="$RPCPORT" getblockcount 2>/dev/null || echo "")"
    case "$H" in
        ''|*[!0-9]*) printf '.' ; continue ;;
    esac
    HEIGHT="$H"
    printf '\r  syncing  height %-8s (%ss)' "$HEIGHT" "$ELAPSED"
    [ "$HEIGHT" -ge "$TARGET" ] && break
done
echo

if [ "$HEIGHT" -lt "$TARGET" ]; then
    bad "reached only height $HEIGHT of $TARGET in ${TIMEOUT_SEC}s"
    echo
    echo "        This is not necessarily a consensus failure -- it may be a"
    echo "        network one. The last lines the node wrote:"
    tail -20 "$DATADIR"/testnet*/debug.log 2>/dev/null | sed 's/^/          /'
    exit 1
fi
ok "synced to height $HEIGHT from genesis, over the real network"

echo
FAILED=0
CHECKED=0
# Read the list on fd 3, not stdin.
#
# wam-cli inherits stdin, and a child that reads it swallows the rest of the
# file -- the loop then runs once and reports "1 block matches", which is a
# pass issued for three checks that never happened. The same shape as the ISA
# check counting a file it could not disassemble.
while read -r h want <&3; do
    case "$h" in ''|\#*) continue ;; esac
    got="$("$CLI" -testnet -datadir="$DATADIR_NATIVE" -rpcport="$RPCPORT" getblockhash "$h" 2>/dev/null </dev/null || echo "")"
    CHECKED=$((CHECKED + 1))
    if [ "$got" = "$want" ]; then
        ok "height $h matches"
    else
        bad "height $h DISAGREES"
        printf '          this binary: %s\n' "${got:-<no answer>}"
        printf '          the chain   : %s\n' "$want"
        FAILED=$((FAILED + 1))
    fi
done 3< "$KNOWN"

echo
echo "=================================================================="
if [ "$CHECKED" -eq 0 ]; then
    bad "no height was compared -- this proves nothing"
    exit 2
fi
if [ "$FAILED" -eq 0 ]; then
    printf ' %s%severy one of %d blocks matches the running chain%s\n' \
        "$GRN" "$BLD" "$CHECKED" "$OFF"
    echo "=================================================================="
    echo
    exit 0
fi
printf ' %s%d of %d blocks disagree -- do not publish this binary%s\n' \
    "$RED" "$FAILED" "$CHECKED" "$OFF"
echo
echo " Two different problems look identical here:"
echo
echo "  * this binary validates differently from the Linux nodes, which is"
echo "    what this test is for; or"
echo "  * the test chain was reset again, which has happened twice, and every"
echo "    line in scripts/test/known_testnet_blocks.txt went stale at once."
echo
echo " Tell them apart by asking a Linux node for the same height:"
echo "     wam-cli -testnet getblockhash 6000"
echo " If it answers what this binary answered, the file is stale, not the"
echo " binary. If it answers what the file says, the binary is wrong."
echo "=================================================================="
echo
exit 1

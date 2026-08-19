#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_fresh_sync.sh -- can a stranger actually join this network?
# ===========================================================================
#
#      bash scripts/check_fresh_sync.sh --network testnet --peer IP:PORT
#      bash scripts/check_fresh_sync.sh --network testnet --peer IP:PORT \
#           --binary /path/to/wamd
#
#  WHY THIS EXISTS
#
#  On 2026-08-20 the testnet chain could not be validated from its genesis
#  block. Blocks 1 to 30 paid the 5% treasury share to the founder address;
#  block 31 onwards paid it to the separate treasury address that replaced it.
#  Current software rejects the first group:
#
#      ConnectBlock 11b46246... failed, bad-cb-devfee-amount, coinbase pays
#      0.00000000 WAM to the development treasury but consensus requires at
#      least 2.50000000 WAM ... to be sent to TQkMCz...
#
#  Both running nodes were perfectly happy. They had those blocks in their
#  chainstate from before the rule changed, and a node does not re-validate
#  history it has already accepted. Every check available agreed: the services
#  were up, the nodes ran byte-identical binaries, they held the same block at
#  the same height, the ports answered, the release matched the source.
#
#  All of them were true. All of them missed it, because every one asks about
#  a node that already has the chain. The only question that finds this is
#  whether a node that has NOTHING can get the chain -- which is also the only
#  question the network's users are actually asking.
#
#  It is found by accident or not at all: someone wipes a datadir, or a new
#  miner joins, or an exchange syncs a node for a listing. On mainnet the first
#  of those is an exchange, and the answer arrives in public.
#
#  So: a real node, an empty directory, and the chain or a reason why not.
#
#  WHAT COUNTS AS PASSING
#
#  Reaching the peer's height. Not "no errors" -- a node stuck at height 0 logs
#  its refusal once and then sits quietly, which reads like patience.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NETWORK="testnet"
PEER=""
BINARY=""
WAIT=240

while [ $# -gt 0 ]; do
    case "$1" in
        --network) NETWORK="${2:?--network needs a value}"; shift 2 ;;
        --peer)    PEER="${2:?--peer needs a value}";       shift 2 ;;
        --binary)  BINARY="${2:?--binary needs a value}";   shift 2 ;;
        --timeout) WAIT="${2:?--timeout needs a value}";    shift 2 ;;
        -h|--help) sed -n '5,45p' "$0"; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

case "$NETWORK" in
    mainnet) NETFLAG=""; DEFPORT=9555  ;;
    testnet) NETFLAG="-testnet"; DEFPORT=19555 ;;
    *) printf 'network must be mainnet or testnet\n' >&2; exit 2 ;;
esac

[ -n "$PEER" ] || { printf 'usage: %s --network NET --peer IP[:PORT]\n' "${0##*/}" >&2; exit 2; }
case "$PEER" in *:*) ;; *) PEER="$PEER:$DEFPORT" ;; esac

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'

# Whatever a user would run, in the order they would find it.
if [ -z "$BINARY" ]; then
    for c in "$(command -v wamd 2>/dev/null)" \
             "$HERE/build/wam-core/src/wamd" \
             "$HOME/wam/build/wam-core/src/wamd"; do
        [ -n "$c" ] && [ -x "$c" ] && { BINARY="$c"; break; }
    done
fi
[ -n "$BINARY" ] && [ -x "$BINARY" ] || {
    printf 'no wamd found -- pass --binary\n' >&2; exit 3; }
CLI="$(dirname "$BINARY")/wam-cli"
[ -x "$CLI" ] || CLI="$(command -v wam-cli 2>/dev/null)"
[ -n "$CLI" ] && [ -x "$CLI" ] || { printf 'no wam-cli beside %s\n' "$BINARY" >&2; exit 3; }

echo "=================================================================="
echo " Can a node with nothing reach this chain?"
echo "=================================================================="
printf '\n  binary  %s\n  peer    %s\n  network %s\n\n' "$BINARY" "$PEER" "$NETWORK"

DD="$(mktemp -d)"
# A port nobody is using, so this never collides with a node already running
# on this machine -- the usual reason a check like this "fails" for no reason.
RPCPORT=0
for p in $(seq 39557 39599); do
    (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null || { RPCPORT=$p; break; }
done
[ "$RPCPORT" != 0 ] || { echo "no free port"; rm -rf "$DD"; exit 3; }

cleanup() {
    "$CLI" $NETFLAG -datadir="$DD" -rpcport="$RPCPORT" -rpcuser=f -rpcpassword=f stop >/dev/null 2>&1
    sleep 3
    pkill -f "datadir=$DD" >/dev/null 2>&1
    rm -rf "$DD"
}
trap cleanup EXIT

"$BINARY" $NETFLAG -datadir="$DD" -rpcport="$RPCPORT" -rpcuser=f -rpcpassword=f \
    -connect="$PEER" -listen=0 -printtoconsole=1 -dnsseed=0 \
    > "$DD/node.log" 2>&1 &

ask() { "$CLI" $NETFLAG -datadir="$DD" -rpcport="$RPCPORT" -rpcuser=f -rpcpassword=f "$@" 2>/dev/null; }

for i in $(seq 1 40); do
    sleep 3
    [ -n "$(ask getblockcount)" ] && break
done
if [ -z "$(ask getblockcount)" ]; then
    printf '  %sFAIL%s   the node never answered. Last words:\n' "$RED" "$OFF"
    tail -8 "$DD/node.log" | sed 's/^/           /'
    exit 1
fi

TARGET=""
LAST=-1
STUCK=0
printf '  %-8s %-8s %-8s %s\n' "elapsed" "blocks" "headers" "peer height"
for i in $(seq 1 $((WAIT / 5))); do
    H="$(ask getblockcount)"
    HDR="$(ask getblockchaininfo | grep -oE '"headers": [0-9]+' | grep -oE '[0-9]+')"
    [ -z "$TARGET" ] && TARGET="$(ask getpeerinfo | grep -oE '"startingheight": [0-9]+' | grep -oE '[0-9]+' | head -1)"

    printf '  %-8s %-8s %-8s %s\n' "$((i * 5))s" "${H:-?}" "${HDR:-?}" "${TARGET:-?}"

    if [ -n "$TARGET" ] && [ -n "$H" ] && [ "$H" -ge "$TARGET" ] 2>/dev/null; then
        echo
        printf ' %sa new node reached height %s -- strangers can join%s\n' "$GRN" "$H" "$OFF"
        echo "=================================================================="
        exit 0
    fi

    if [ "$H" = "$LAST" ]; then STUCK=$((STUCK + 1)); else STUCK=0; fi
    LAST="$H"
    # Six identical readings is half a minute of no progress with headers
    # already known. That is not slow, it is refusing.
    if [ "$STUCK" -ge 6 ] && [ -n "$HDR" ] && [ "$HDR" -gt "${H:-0}" ] 2>/dev/null; then
        break
    fi
    sleep 2
done

echo
printf ' %sa new node did NOT reach the tip%s\n' "$RED" "$OFF"
printf '   stopped at block %s while the peer offers %s\n' "${LAST}" "${TARGET:-?}"
echo
REASON="$(grep -iE 'ConnectBlock .* failed|bad-[a-z-]+|InvalidChainFound: invalid' "$DD/node.log" | tail -3)"
if [ -n "$REASON" ]; then
    echo "   the node said why:"
    printf '%s\n' "$REASON" | sed 's/^/     /'
    echo
    echo "   A chain whose early blocks were mined under a rule that has since"
    echo "   changed cannot be validated from genesis. Running nodes accept it"
    echo "   only because they never re-check history. Nobody new can join, and"
    echo "   restarting the chain is the only honest repair."
else
    echo "   nothing in the log explains it. Last lines:"
    tail -6 "$DD/node.log" | sed 's/^/     /'
fi
echo "=================================================================="
exit 1

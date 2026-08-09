#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  import_founder_key.sh -- load a founder WIF into a descriptor wallet
# ===========================================================================
#
#      bash scripts/import_founder_key.sh --network testnet
#
#  Bitcoin Core v28 wallets are descriptor wallets, and importprivkey is a
#  legacy-only RPC. The equivalent is importdescriptors with a pkh() descriptor
#  carrying the key -- which needs a checksum, which needs a round trip through
#  getdescriptorinfo. Doing that by hand means the key lands in shell history
#  and in the process list, so this script does it instead.
#
#  Three precautions, none of them optional for a key that matters:
#
#    * read -s     -- the key is never echoed to the terminal
#    * -stdin      -- bitcoin-cli reads it from a pipe, so it never appears in
#                     `ps` output where any other user on the box can see it
#    * HISTIGNORE  -- nothing about this invocation carries the key, because
#                     the key is never an argument
#
#  It prints the derived address and compares it with the one the chain expects,
#  so a mistyped key fails here rather than silently importing a wallet that
#  controls nothing.
# ===========================================================================

set -uo pipefail

NETWORK="testnet"
WALLET="founder"
CLI="./src/wam-cli"
DATADIR=""
RPCPORT=""
RPCUSER="t"
RPCPASS="t"
EXPECT_ADDR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --network) NETWORK="$2"; shift ;;
        --wallet)  WALLET="$2"; shift ;;
        --cli)     CLI="$2"; shift ;;
        --datadir) DATADIR="$2"; shift ;;
        --rpcport) RPCPORT="$2"; shift ;;
        --rpcuser) RPCUSER="$2"; shift ;;
        --rpcpassword) RPCPASS="$2"; shift ;;
        --expect-address) EXPECT_ADDR="$2"; shift ;;
        -h|--help) sed -n '5,30p' "$0"; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

case "$NETWORK" in
    mainnet) NETFLAG="";          DEFPORT=9556  ;;
    testnet) NETFLAG="-testnet";  DEFPORT=19556 ;;
    regtest) NETFLAG="-regtest";  DEFPORT=29556 ;;
    *) echo "unknown network $NETWORK" >&2; exit 2 ;;
esac

[ -n "$RPCPORT" ] || RPCPORT="$DEFPORT"
[ -n "$DATADIR" ] || DATADIR="$HOME/wam-$NETWORK"

# shellcheck disable=SC2206
BASE=($CLI $NETFLAG "-datadir=$DATADIR" "-rpcport=$RPCPORT"
      "-rpcuser=$RPCUSER" "-rpcpassword=$RPCPASS")

echo "======================================================================"
echo " IMPORT FOUNDER KEY -- $NETWORK / wallet '$WALLET'"
echo "======================================================================"

if ! "${BASE[@]}" getblockcount >/dev/null 2>&1; then
    echo "  error: cannot reach the $NETWORK node at 127.0.0.1:$RPCPORT" >&2
    exit 1
fi

if ! "${BASE[@]}" listwallets 2>/dev/null | grep -q "\"$WALLET\""; then
    echo "  loading wallet '$WALLET'..."
    "${BASE[@]}" loadwallet "$WALLET" >/dev/null 2>&1 \
        || { echo "  error: wallet '$WALLET' does not exist. Create it with:"; \
             echo "         ${BASE[*]} createwallet $WALLET"; exit 1; }
fi

echo
echo "  Paste or type the WIF from your paper backup."
echo "  It will NOT be shown, NOT stored in shell history, and NOT passed as a"
echo "  command-line argument (so it never appears in 'ps')."
echo
read -r -s -p "  WIF: " WIF
echo
echo

if [ -z "$WIF" ]; then
    echo "  nothing entered"; exit 2
fi

# ---- checksum, via stdin so the key stays out of the process list ---------
INFO=$(printf '%s\n' "pkh($WIF)" | "${BASE[@]}" -stdin getdescriptorinfo 2>&1)
CHECKSUM=$(printf '%s' "$INFO" | grep -oP '"checksum"\s*:\s*"\K[^"]+')

if [ -z "$CHECKSUM" ]; then
    echo "  FAILED to build a descriptor from that key."
    echo "  The node said:"
    printf '%s\n' "$INFO" | grep -v "$WIF" | sed 's/^/    /' | head -5
    echo
    echo "  Most likely the WIF has a wrong character. Re-read your paper copy."
    unset WIF
    exit 1
fi

# ---- import ---------------------------------------------------------------
REQ=$(printf '[{"desc":"pkh(%s)#%s","timestamp":0,"internal":false,"active":false,"label":"founder"}]' \
      "$WIF" "$CHECKSUM")

RESULT=$(printf '%s\n' "$REQ" | "${BASE[@]}" "-rpcwallet=$WALLET" -stdin importdescriptors 2>&1)
unset WIF REQ    # the key leaves this shell here

if printf '%s' "$RESULT" | grep -q '"success": *true'; then
    echo "  import: SUCCESS"
else
    echo "  import: FAILED"
    printf '%s\n' "$RESULT" | sed 's/^/    /' | head -12
    exit 1
fi

# ---- verify the wallet now controls what we expect ------------------------
echo
echo "  addresses this wallet can now sign for:"
ADDRS=$("${BASE[@]}" "-rpcwallet=$WALLET" getaddressesbylabel founder 2>/dev/null \
        | grep -oP '"\K[A-Za-z0-9]{25,60}(?=")' | sort -u)

if [ -z "$ADDRS" ]; then
    echo "    (none reported -- import succeeded but no address was labelled)"
else
    printf '    %s\n' $ADDRS
fi

if [ -n "$EXPECT_ADDR" ]; then
    echo
    if printf '%s\n' $ADDRS | grep -qx "$EXPECT_ADDR"; then
        echo "  MATCH -- the wallet controls $EXPECT_ADDR"
    else
        echo "  MISMATCH -- expected $EXPECT_ADDR, which is NOT in the list above."
        echo "  This key does not control the founder address in chainparams."
        exit 1
    fi
fi

echo
echo "  done."

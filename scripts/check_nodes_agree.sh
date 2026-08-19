#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_nodes_agree.sh -- do the deployed nodes run the same rules?
# ===========================================================================
#
#      bash scripts/check_nodes_agree.sh HOST [HOST...]
#
#  WHY THIS EXISTS
#
#  On 2026-08-19 the two testnet nodes ran different builds. One had been
#  installed before the commit that gave the treasury its own address, so it
#  still demanded the 5% go to the founder address; the other paid the new
#  treasury. The older node rejected every block the newer one mined:
#
#      ConnectBlock ... failed, bad-cb-devfee-amount, coinbase pays
#      0.00000000 WAM to the development treasury but consensus requires
#      at least 2.50000000 WAM ... to be sent to TK34fT...
#
#  The chain split at height 31 and stayed split for hours. Nothing noticed,
#  because every check anyone runs asks a node about itself:
#
#      systemctl is-active wamd     -> active, on both
#      getblockcount                -> a number, on both
#      getnetworkinfo subversion    -> /WAM:0.1.0/, on BOTH
#
#  That last one is the trap. The two binaries differed in a consensus rule
#  and reported an identical version string, so no amount of asking one node
#  how it is could ever reveal it. The only question that finds this is one
#  node compared against another.
#
#  Run this after deploying to any node, and before a launch. The cost of not
#  running it is a chain that silently forks the moment a miner finds a block.
#
#  WHAT IT REFUSES TO CONFUSE
#
#  Lag is not a fork. A node two blocks behind is normal; a node with a
#  different block at a height both have reached is not. So the comparison is
#  made at the lowest height every node has, never at their tips.
# ===========================================================================

set -uo pipefail

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
FAIL=0

ok()   { printf '  %sok%s     %s\n' "$GRN" "$OFF" "$*"; }
bad()  { printf '  %sFAIL%s   %s\n' "$RED" "$OFF" "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  %swarn%s   %s\n' "$YLW" "$OFF" "$*"; }

if [ $# -lt 2 ]; then
    printf 'usage: %s HOST [HOST...]\n\n' "${0##*/}" >&2
    printf 'Two hosts minimum -- agreement is not a property one node has.\n' >&2
    exit 2
fi

HOSTS=("$@")

rsh() {
    timeout 45 ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$1" "$2" 2>/dev/null
}

echo "=================================================================="
echo " Do the deployed nodes agree?"
echo "=================================================================="

# ---------------------------------------------------------------------------
printf '\n%sreachable%s\n' "$BLD" "$OFF"

LIVE=()
for h in "${HOSTS[@]}"; do
    if [ -n "$(rsh "$h" 'wam-cli getblockcount')" ]; then
        ok "$h"
        LIVE+=("$h")
    else
        bad "$h -- no answer from wam-cli over ssh"
    fi
done

if [ "${#LIVE[@]}" -lt 2 ]; then
    printf '\n%sfewer than two nodes answered -- nothing can be compared%s\n' "$RED" "$OFF"
    exit 1
fi

# ---------------------------------------------------------------------------
printf '\n%sthe same code%s\n' "$BLD" "$OFF"

# Every wam-* executable, not just wamd. A wam-cli that disagrees with its
# daemon is a subtler version of the same problem.
#
# LC_ALL=C on the sort is load-bearing, not decoration. Without it each host
# sorts in its own locale: under C the hyphen sorts before a letter, so wamd
# comes last, while a UTF-8 locale ignores punctuation in its first pass and
# puts wamd second. Identical binaries then produce differently ordered lists
# and this reports a disagreement that does not exist -- and a check that
# cries wolf is one nobody reads, which is the failure this file exists to
# prevent.
declare -A FINGERPRINT
for h in "${LIVE[@]}"; do
    FINGERPRINT[$h]="$(rsh "$h" 'for f in /usr/local/bin/wam*; do printf "%s %s\n" "${f##*/}" "$(sha256sum "$f" | cut -c1-16)"; done | LC_ALL=C sort' | tr -d '\r')"
done

REF="${LIVE[0]}"
for h in "${LIVE[@]:1}"; do
    if [ "${FINGERPRINT[$h]}" = "${FINGERPRINT[$REF]}" ]; then
        ok "$h runs byte-identical binaries to $REF"
    else
        bad "$h and $REF run DIFFERENT binaries -- they may enforce different rules"
        diff <(printf '%s\n' "${FINGERPRINT[$REF]}") \
             <(printf '%s\n' "${FINGERPRINT[$h]}") 2>/dev/null \
            | grep -E '^[<>]' | sed "s/^/           /"
        printf '           %s is < , %s is >\n' "$REF" "$h"
    fi
done

# ---------------------------------------------------------------------------
printf '\n%sthe same chain%s\n' "$BLD" "$OFF"

declare -A GENESIS HEIGHT
for h in "${LIVE[@]}"; do
    GENESIS[$h]="$(rsh "$h" 'wam-cli getblockhash 0' | tr -d '\r\n ')"
    HEIGHT[$h]="$(rsh "$h" 'wam-cli getblockcount' | tr -d '\r\n ')"
done

for h in "${LIVE[@]:1}"; do
    if [ -n "${GENESIS[$h]}" ] && [ "${GENESIS[$h]}" = "${GENESIS[$REF]}" ]; then
        ok "$h shares the genesis block of $REF"
    else
        bad "$h is on a DIFFERENT NETWORK -- genesis ${GENESIS[$h]:0:16} vs ${GENESIS[$REF]:0:16}"
    fi
done

# ---------------------------------------------------------------------------
printf '\n%sthe same history%s\n' "$BLD" "$OFF"

COMMON=""
for h in "${LIVE[@]}"; do
    n="${HEIGHT[$h]}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    { [ -z "$COMMON" ] || [ "$n" -lt "$COMMON" ]; } && COMMON="$n"
done

if [ -z "$COMMON" ]; then
    bad "no node reported a usable height"
else
    printf '  comparing at height %s, the lowest every node has reached\n' "$COMMON"
    declare -A ATCOMMON
    for h in "${LIVE[@]}"; do
        ATCOMMON[$h]="$(rsh "$h" "wam-cli getblockhash $COMMON" | tr -d '\r\n ')"
        printf '    %-18s tip=%-6s block[%s]=%s\n' \
            "$h" "${HEIGHT[$h]}" "$COMMON" "${ATCOMMON[$h]:0:24}"
    done

    SPLIT=0
    for h in "${LIVE[@]:1}"; do
        [ "${ATCOMMON[$h]}" = "${ATCOMMON[$REF]}" ] || SPLIT=1
    done

    if [ "$SPLIT" -eq 0 ] && [ -n "${ATCOMMON[$REF]}" ]; then
        ok "every node has the same block at height $COMMON -- one chain"
    else
        bad "the nodes have DIFFERENT blocks at height $COMMON -- the chain has forked"
    fi
fi

# A node far behind is not a fork, but it is not serving anyone either.
for h in "${LIVE[@]:1}"; do
    a="${HEIGHT[$REF]}"; b="${HEIGHT[$h]}"
    case "$a$b" in ''|*[!0-9]*) continue ;; esac
    d=$(( a > b ? a - b : b - a ))
    [ "$d" -gt 6 ] && warn "$h is $d blocks from $REF -- lag, or the start of a split"
done

echo
echo "=================================================================="
if [ "$FAIL" -eq 0 ]; then
    printf ' %sall %d nodes agree%s\n' "$GRN" "${#LIVE[@]}" "$OFF"
else
    printf ' %s%d disagreement(s) -- do not launch on this%s\n' "$RED" "$FAIL" "$OFF"
fi
echo "=================================================================="
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_nodes_agree.sh -- do the deployed nodes run the same rules?
# ===========================================================================
#
#      bash scripts/check_nodes_agree.sh HOST [HOST...]
#      bash scripts/check_nodes_agree.sh --network testnet HOST [HOST...]
#
#  IT DEFAULTS TO MAINNET, AND IT USED TO ANSWER ABOUT TESTNET
#
#  Until 18 September 2026 every wam-cli here was bare. On these servers the
#  default datadir is /root/.wam, whose wam.conf says testnet=1, so bare
#  wam-cli is the testnet node. Three days into mainnet this printed
#
#      comparing at height 9964 ... one chain | all 3 nodes agree
#
#  about testnet, while mainnet stood at 2382. Genesis hashes matched --
#  because they were three copies of the same wrong chain -- so nothing in the
#  output looked off. The check that exists to catch a consensus split was
#  looking at a network with nothing at stake, and the sweep scored it green.
#
#  The network is now named on every call, and printed in the header, so the
#  question "which chain did this answer about" always has a visible answer.
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

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPTS_DIR/lib/python.sh"
. "$SCRIPTS_DIR/lib/wamcli.sh"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
FAIL=0       # nodes were compared and they differ          -> exit 1
UNKNOWN=0    # a node was never read, so nothing compared    -> exit 2

ok()   { printf '  %sok%s     %s\n' "$GRN" "$OFF" "$*"; }
bad()  { printf '  %sFAIL%s   %s\n' "$RED" "$OFF" "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  %swarn%s   %s\n' "$YLW" "$OFF" "$*"; }

# A question that was never asked. Separate from bad() because the summary of
# this check ends with "do not launch on this", and an ssh timeout is not a
# reason not to launch -- it is a reason to look again. Until 2026-09-14,
# ten hours before mainnet, an unreachable host came out of here in red.
unknown() { printf '  %s??%s     %s\n' "$YLW" "$OFF" "$*"; UNKNOWN=$((UNKNOWN + 1)); }

# Mainnet is the default because mainnet is the chain with coins on it. A
# script that has to be told which network to examine will eventually be run
# without being told, and the harmless default is the one that examines the
# chain that matters.
NETWORK=mainnet
HOSTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --network) NETWORK="${2:?--network needs a value}"; shift 2 ;;
        -h|--help) sed -n '5,25p' "$0"; exit 0 ;;
        -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
        *) HOSTS+=("$1"); shift ;;
    esac
done

if [ "${#HOSTS[@]}" -lt 2 ]; then
    printf 'usage: %s [--network NET] HOST [HOST...]\n\n' "${0##*/}" >&2
    printf 'Two hosts minimum -- agreement is not a property one node has.\n' >&2
    exit 2
fi

# Resolved once, here, so an unknown network stops the run instead of becoming
# an empty flag string -- and an empty flag string is the testnet node.
CLI="wam-cli $(wam_cli_flags "$NETWORK")" || exit 2

# Two attempts, because an empty answer here means "not compared" and one
# lost packet should not cost a comparison. On 18 September a single blip
# reported US-east unread, and with it the only question this file exists to
# answer; the same host answered in three seconds when asked again by hand.
#
# Only an EMPTY reply is retried. A host that answers something -- even an
# error -- has been reached, and asking twice would hide a real fault behind
# a second roll of the dice.
rsh() {
    local out
    out="$(timeout 45 ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o BatchMode=yes -o ConnectTimeout=15 "root@$1" "$2" 2>/dev/null)"
    if [ -z "$out" ]; then
        sleep 2
        out="$(timeout 45 ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o BatchMode=yes -o ConnectTimeout=15 "root@$1" "$2" 2>/dev/null)"
    fi
    printf '%s' "$out"
}

echo "=================================================================="
echo " Do the deployed nodes agree?  [$NETWORK]"
echo "=================================================================="

# ---------------------------------------------------------------------------
printf '\n%sreachable%s\n' "$BLD" "$OFF"

LIVE=()
for h in "${HOSTS[@]}"; do
    if [ -n "$(rsh "$h" "$CLI getblockcount")" ]; then
        ok "$h"
        LIVE+=("$h")
    else
        unknown "$h -- no answer from wam-cli over ssh; it was not compared"
    fi
done

if [ "${#LIVE[@]}" -lt 2 ]; then
    # The line itself says nothing could be compared. Exit 2 says the same
    # thing to the machine reading the exit code, instead of claiming a
    # disagreement between nodes that were never asked.
    printf '\n%sfewer than two nodes answered -- nothing can be compared%s\n' "$YLW" "$OFF"
    exit 2
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
# THE FIVE CONSENSUS PROGRAMS, and deliberately not everything named wam*.
#
# This used to fingerprint /usr/local/bin/wam*, which is also where the
# operational shell scripts live -- wam-backup.sh, wam-concentration-log.sh.
# Those are installed per ROLE: the hourly concentration logger belongs on the
# host that runs the explorer and nowhere else, because there is nothing for it
# to read anywhere else. Installing it produced
#
#     FAIL  <host> and <host> run DIFFERENT binaries -- they may enforce
#           different rules
#     2 disagreement(s) -- do not launch on this
#
# on a network whose five consensus programs were byte-identical. A check that
# says "do not launch" about a log script is a check that gets ignored on the
# day it means something.
#
# A wam-cli that disagrees with its daemon is still a real hazard, so all five
# are compared, not just wamd.
CONSENSUS_BINARIES='wamd wam-cli wam-tx wam-util wam-wallet'

declare -A FINGERPRINT
for h in "${LIVE[@]}"; do
    FINGERPRINT[$h]="$(rsh "$h" "for f in $CONSENSUS_BINARIES; do p=/usr/local/bin/\$f; [ -f \"\$p\" ] && printf '%s %s\n' \"\$f\" \"\$(sha256sum \"\$p\" | cut -c1-16)\"; done | LC_ALL=C sort" | tr -d '\r')"
done

# The helper scripts are still worth a word -- they differ for a reason, and a
# reason someone should be able to state. Said as a note, never as a finding.
declare -A HELPERS
for h in "${LIVE[@]}"; do
    HELPERS[$h]="$(rsh "$h" 'ls -1 /usr/local/bin/wam*.sh 2>/dev/null | xargs -r -n1 basename | LC_ALL=C sort' | tr -d '\r')"
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

# The role scripts, reported and never failed on.
for h in "${LIVE[@]:1}"; do
    if [ "${HELPERS[$h]}" != "${HELPERS[$REF]}" ]; then
        printf '  %snote%s   %s and %s carry different helper scripts, which is\n' \
            "$YLW" "$OFF" "$h" "$REF"
        printf '         expected when they run different services:\n'
        diff <(printf '%s\n' "${HELPERS[$REF]}") \
             <(printf '%s\n' "${HELPERS[$h]}") 2>/dev/null \
            | grep -E '^[<>]' | sed "s/^/           /"
    fi
done

# ---------------------------------------------------------------------------
printf '\n%sthe same chain%s\n' "$BLD" "$OFF"

declare -A GENESIS HEIGHT
for h in "${LIVE[@]}"; do
    GENESIS[$h]="$(rsh "$h" "$CLI getblockhash 0" | tr -d '\r\n ')"
    HEIGHT[$h]="$(rsh "$h" "$CLI getblockcount" | tr -d '\r\n ')"
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
    unknown "no node reported a usable height -- no history was compared"
else
    printf '  comparing at height %s, the lowest every node has reached\n' "$COMMON"
    declare -A ATCOMMON
    for h in "${LIVE[@]}"; do
        ATCOMMON[$h]="$(rsh "$h" "$CLI getblockhash $COMMON" | tr -d '\r\n ')"
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
if [ "$FAIL" -ne 0 ]; then
    printf ' %s%d disagreement(s) -- do not launch on this%s\n' "$RED" "$FAIL" "$OFF"
elif [ "$UNKNOWN" -ne 0 ]; then
    printf ' %sthe %d node(s) that answered agree; %d could not be read%s\n' \
        "$YLW" "${#LIVE[@]}" "$UNKNOWN" "$OFF"
else
    printf ' %sall %d nodes agree%s\n' "$GRN" "${#LIVE[@]}" "$OFF"
fi
echo "=================================================================="

# A real disagreement outranks an unread node: 1 is louder than 2.
if [ "$FAIL" -ne 0 ]; then exit 1; fi
if [ "$UNKNOWN" -ne 0 ]; then exit 2; fi
exit 0

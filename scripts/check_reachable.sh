#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_reachable.sh -- can the outside world actually reach these ports?
# ===========================================================================
#
#      bash scripts/check_reachable.sh --host TARGET --from VANTAGE PORT...
#
#  WHY THIS EXISTS
#
#  On 2026-08-19 the Electrum server ran perfectly, held a valid certificate,
#  listened on 0.0.0.0:50001 and :50002, and `ufw status` showed both ports
#  allowed. It was unreachable from anywhere. The provider drops inbound TCP
#  to any port not on an allow-list kept in their control panel, and a dropped
#  packet is silent: the connection simply hangs.
#
#  Every check anyone had asked the wrong question:
#
#      systemctl is-active   -> active
#      ss -lnt               -> listening on all interfaces
#      ufw status            -> ALLOW
#
#  All three describe the host's intentions. None of them is reachability.
#  Checking that needs a second machine, because a host cannot test whether
#  the world can reach it.
#
#  The same filter was silently blocking 9555. On launch day the mainnet node
#  would have started, listened, and accepted no inbound peer at all, with no
#  error anywhere.
#
#  WHAT THE ANSWERS MEAN
#
#      open      a full TCP handshake from outside. The only good answer.
#      refused   the packet reached the host and nothing was listening.
#                A service problem -- look at the unit.
#      filtered  no answer at all. Something upstream dropped it: the
#                provider's panel, a cloud ACL, a null route. Not your ufw,
#                which would also show as refused if the port were closed.
#
#  A port that is listening locally but filtered from outside is the exact
#  shape of the failure above, so that combination is called out by name.
#
#  PORTS CARRY THEIR INTENT
#
#      9555     must be reachable -- anything else is a fault
#      !9554    must NOT be reachable -- open is the fault
#
#  Without the second form this tool reports the RPC port as broken for being
#  correctly firewalled, and a check that calls the right thing a failure is
#  one people learn to skim past. The negative form also earns its keep: it is
#  the only thing here that would notice an RPC or Redis port becoming
#  reachable, which is a far worse day than an unreachable Electrum server.
# ===========================================================================

set -uo pipefail

TARGET=""; VANTAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host) TARGET="${2:?--host needs a value}"; shift 2 ;;
        --from) VANTAGE="${2:?--from needs a value}"; shift 2 ;;
        -h|--help) sed -n '5,50p' "$0"; exit 0 ;;
        -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
        *) break ;;
    esac
done

if [ -z "$TARGET" ] || [ -z "$VANTAGE" ] || [ $# -eq 0 ]; then
    printf 'usage: %s --host TARGET --from VANTAGE PORT [PORT...]\n\n' "${0##*/}" >&2
    printf 'VANTAGE must be a different machine. A host cannot prove it is\n' >&2
    printf 'reachable by asking itself.\n' >&2
    exit 2
fi

if [ "$TARGET" = "$VANTAGE" ]; then
    printf 'the vantage point must not be the target -- that proves nothing\n' >&2
    exit 2
fi

# A leading ! means "this must NOT be reachable". The bare number is stripped
# for the probe; the intent is remembered separately.
declare -A MUST_BE_CLOSED
PORTS=()
for spec in "$@"; do
    case "$spec" in
        \!*) p="${spec#!}"; MUST_BE_CLOSED[$p]=1 ;;
        *)   p="$spec" ;;
    esac
    case "$p" in
        ''|*[!0-9]*) printf 'not a port: %s\n' "$spec" >&2; exit 2 ;;
    esac
    PORTS+=("$p")
done

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
FAIL=0

rsh() { timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$1" "$2" 2>/dev/null; }

echo "=================================================================="
echo " Reachability of $TARGET, seen from $VANTAGE"
echo "=================================================================="

# What the target believes about itself, gathered once.
LISTENING="$(rsh "$TARGET" 'ss -lnt' | grep -oE ':[0-9]+ ' | tr -d ': ' | sort -u)"
if [ -z "$LISTENING" ]; then
    printf '\n  %swarn%s   could not read the listening sockets on %s\n' "$YLW" "$OFF" "$TARGET"
fi

# The probe runs on the vantage machine. bash's /dev/tcp gives us the three
# outcomes apart: success, a fast refusal, and a timeout that never answers.
PROBE='
for p in PORTLIST; do
    if timeout 8 bash -c "exec 3<>/dev/tcp/TARGETIP/$p" 2>/dev/null; then
        echo "$p open"
    elif timeout 8 bash -c "exec 3<>/dev/tcp/TARGETIP/$p" 2>&1 | grep -qi refused; then
        echo "$p refused"
    else
        echo "$p filtered"
    fi
done'
PROBE="${PROBE//PORTLIST/${PORTS[*]}}"
PROBE="${PROBE//TARGETIP/$TARGET}"

RESULT="$(rsh "$VANTAGE" "$PROBE")"
if [ -z "$RESULT" ]; then
    printf '\n  %sFAIL%s   the vantage machine %s did not answer -- nothing was tested\n' \
        "$RED" "$OFF" "$VANTAGE"
    echo; echo "=================================================================="
    exit 1
fi

printf '\n%s%-8s %-11s %-11s %s%s\n' "$BLD" "port" "from outside" "listening" "verdict" "$OFF"

while read -r port state; do
    [ -n "$port" ] || continue
    if printf '%s\n' "$LISTENING" | grep -qx "$port"; then LIS="yes"; else LIS="no"; fi

    if [ -n "${MUST_BE_CLOSED[$port]:-}" ]; then
        # Sealed on purpose. Only "open" is wrong here, and it is very wrong.
        if [ "$state" = "open" ]; then
            printf '  %-8s %s%-11s%s %-11s %sEXPOSED -- this must not be reachable%s\n' \
                "$port" "$RED" "open" "$OFF" "$LIS" "$RED" "$OFF"
            FAIL=$((FAIL + 1))
        else
            printf '  %-8s %s%-11s%s %-11s sealed, as intended\n' \
                "$port" "$GRN" "$state" "$OFF" "$LIS"
        fi
        continue
    fi

    case "$state:$LIS" in
        open:*)
            printf '  %-8s %s%-11s%s %-11s reachable\n' "$port" "$GRN" "open" "$OFF" "$LIS" ;;
        filtered:yes)
            printf '  %-8s %s%-11s%s %-11s %sDROPPED UPSTREAM -- the service is fine,\n' \
                "$port" "$RED" "filtered" "$OFF" "$LIS" "$RED"
            printf '           something above this host is discarding the packets%s\n' "$OFF"
            FAIL=$((FAIL + 1)) ;;
        filtered:no)
            printf '  %-8s %s%-11s%s %-11s nothing listening AND filtered\n' \
                "$port" "$RED" "filtered" "$OFF" "$LIS"
            FAIL=$((FAIL + 1)) ;;
        refused:*)
            printf '  %-8s %s%-11s%s %-11s reached the host, nothing listening\n' \
                "$port" "$YLW" "refused" "$OFF" "$LIS"
            FAIL=$((FAIL + 1)) ;;
        *)
            printf '  %-8s %-11s %-11s unexpected\n' "$port" "$state" "$LIS"
            FAIL=$((FAIL + 1)) ;;
    esac
done <<< "$RESULT"

echo
echo "=================================================================="
if [ "$FAIL" -eq 0 ]; then
    printf ' %severy port is reachable from outside%s\n' "$GRN" "$OFF"
else
    printf ' %s%d port(s) not reachable%s\n' "$RED" "$FAIL" "$OFF"
fi
echo "=================================================================="
[ "$FAIL" -eq 0 ]

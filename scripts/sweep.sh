#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  sweep.sh -- run every check there is, and say what was not run
# ===========================================================================
#
#      bash scripts/sweep.sh
#      bash scripts/sweep.sh --nodes "1.2.3.4 5.6.7.8"     # also the live ones
#
#  WHY THIS EXISTS
#
#  The checks in this directory were each written after something went wrong,
#  and each of them works. On 2026-08-19 three faults were nevertheless live
#  at the same time:
#
#    - the published v0.1.0 download was a different network entirely, four
#      days after the genesis blocks were re-mined
#    - the two deployed nodes ran different consensus binaries and the chain
#      had been split for six hours
#    - the Electrum server was unreachable from the internet, and so was the
#      mainnet p2p port, which would have failed silently on launch day
#
#  None of them was subtle. All of them would have been caught in under a
#  minute. They survived because running the checks depended on remembering
#  to run the checks, one at a time, and nothing listed what had not been run.
#
#  So this is one command, and its most important column is the one that says
#  SKIPPED. A check that was not run is not a check that passed, and the
#  summary refuses to let those look alike.
#
#  Run it at the start of a working session and before anything is announced.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

NODES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --nodes) NODES="${2:?--nodes needs a value}"; shift 2 ;;
        -h|--help) sed -n '5,32p' "$0"; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
PASSED=(); FAILED=(); SKIPPED=()
LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT

# run NAME -- COMMAND...
run() {
    local name="$1"; shift
    local log="$LOGDIR/${name// /_}.log"
    printf '  %-34s ' "$name"
    if "$@" >"$log" 2>&1; then
        printf '%sok%s\n' "$GRN" "$OFF"
        PASSED+=("$name")
    else
        printf '%sFAIL%s\n' "$RED" "$OFF"
        FAILED+=("$name")
        sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -iE '^ *(FAIL|error|✗)' | head -4 \
            | sed 's/^/       /'
    fi
}

skip() {
    printf '  %-34s %sSKIPPED%s  %s\n' "$1" "$YLW" "$OFF" "$2"
    SKIPPED+=("$1 -- $2")
}

echo "=================================================================="
echo " WAM sweep -- $(date '+%Y-%m-%d %H:%M')"
echo "=================================================================="

# ---------------------------------------------------------------------------
printf '\n%sthe repository%s\n' "$BLD" "$OFF"

run "repository self-agreement"  bash scripts/audit_repo.sh
run "vesting tables agree"       python3 scripts/check_vesting_sync.py
run "supply arithmetic"          python3 scripts/verify_supply.py
run "executable bits in index"   bash scripts/test/test_exec_bits.sh
run "service hardening"          bash scripts/test/test_harden.sh

# Asked before a chain is started, not after. A consensus value that changes
# once blocks exist invalidates every block mined under the old one, and the
# running nodes are the last to notice.
run "testnet consensus is final"  bash scripts/check_consensus_final.sh testnet
run "mainnet consensus is final"  bash scripts/check_consensus_final.sh mainnet

# ---------------------------------------------------------------------------
printf '\n%sthe network as strangers meet it%s\n' "$BLD" "$OFF"

if command -v dig >/dev/null 2>&1; then
    run "DNS seeds answer x9."    bash scripts/check_dns_seeds.sh
else
    skip "DNS seeds answer x9." "dig is not installed (apt install dnsutils)"
fi

if command -v curl >/dev/null 2>&1; then
    run "published download is this network" bash scripts/check_release_matches.sh
else
    skip "published download is this network" "curl is not installed"
fi

# ---------------------------------------------------------------------------
printf '\n%sthe deployed machines%s\n' "$BLD" "$OFF"

if [ -z "$NODES" ]; then
    skip "nodes agree with each other" "no --nodes given"
    skip "ports reachable from outside" "no --nodes given"
else
    set -- $NODES
    if [ $# -lt 2 ]; then
        skip "nodes agree with each other" "--nodes needs two or more hosts"
        skip "ports reachable from outside" "--nodes needs two or more hosts"
    else
        run "nodes agree with each other" bash scripts/check_nodes_agree.sh $NODES

        # The node binaries are only part of what this repository deploys. The
        # pool, the bot and the dashboard drift the same way and are noticed
        # far later, because the wrong version of working software produces no
        # symptom at all.
        run "deployed code is origin/main" bash scripts/check_deployed_code.sh $NODES

        # The one question the nodes themselves cannot answer. They agreed with
        # each other, ran identical binaries, held the same block at the same
        # height -- and the chain could not be validated from genesis by anyone
        # who did not already have it.
        set -- $NODES
        run "a new node can sync from genesis" \
            bash scripts/check_fresh_sync.sh --network testnet --peer "$1" --timeout 120
        # Each node is probed from the next one round-robin, so every host is
        # examined from a machine that is not itself.
        i=0
        for target in $NODES; do
            i=$((i + 1))
            vantage=""
            for v in $NODES; do [ "$v" != "$target" ] && { vantage="$v"; break; }; done
            run "ports reachable: $target" bash scripts/check_reachable.sh \
                --host "$target" --from "$vantage" 22 19555 '!19554'
        done
    fi
fi

# ---------------------------------------------------------------------------
printf '\n%slaunch readiness%s\n' "$BLD" "$OFF"

if [ -n "$NODES" ]; then
    run "preflight" bash scripts/preflight.sh --nodes "$NODES"
else
    run "preflight" bash scripts/preflight.sh
fi

# ---------------------------------------------------------------------------
echo
echo "=================================================================="
printf ' %s%d passed%s   %s%d failed%s   %s%d NOT RUN%s\n' \
    "$GRN" "${#PASSED[@]}" "$OFF" "$RED" "${#FAILED[@]}" "$OFF" \
    "$YLW" "${#SKIPPED[@]}" "$OFF"

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo
    echo " failed:"
    for f in "${FAILED[@]}"; do printf '   - %s\n' "$f"; done
fi

if [ "${#SKIPPED[@]}" -gt 0 ]; then
    echo
    echo " not run -- these are not passes:"
    for s in "${SKIPPED[@]}"; do printf '   - %s\n' "$s"; done
fi
echo "=================================================================="

[ "${#FAILED[@]}" -eq 0 ]

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
    # Every character that is not a letter, digit or dash becomes an
    # underscore. This replaced spaces only, so the first check whose name
    # contained a '/' -- "deployed code is origin/main" -- turned into a path
    # through a directory that does not exist, and the runner reported a
    # failure of its own making on top of whatever the check actually said.
    local log="$LOGDIR/$(printf '%s' "$name" | tr -c 'A-Za-z0-9-' '_').log"
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

# The listing entry repeats constants that live in src/wam. Hand-written
# copies drift, and this one is read by software rather than by a person: a
# wrong pubtype does not look wrong, it sends somebody's coins nowhere. The
# dangerous day is not the day it was written but the day a prefix changes
# and nobody remembers that a file in integration/ repeats it.
run "the listing entry matches source" python3 scripts/check_listing_entry.py
run "vesting tables agree"       python3 scripts/check_vesting_sync.py
run "supply arithmetic"          python3 scripts/verify_supply.py
run "executable bits in index"   bash scripts/test/test_exec_bits.sh

# Its neighbour above checks that a script is marked runnable. This checks
# that it can actually run. A carriage return at the end of a shebang line
# makes the kernel look for an interpreter named "python3\r", and the error
# it prints says nothing about why. gen_founder_key.py -- run once, from a
# live USB, by one person -- sat in this repository that way.
run "line endings are LF"        bash scripts/test/test_line_endings.sh
run "service hardening"          bash scripts/test/test_harden.sh

# systemd sets no HOME for a service with no User=, so wam-cli looks in
# /.wam and reports missing RPC credentials -- which reads as a node that is
# down while the node is up. It killed the backups for three days in August,
# and then killed the reorg watcher on the day it was written, by the same
# person, hours after he wrote the check that would have caught the first
# one. Knowing about a trap is not a guard rail.
run "units that resolve ~ have a HOME"  bash scripts/test/test_service_home.sh

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

        # The service every check here had been ignoring.
        #
        # On 2026-08-20 the Electrum server was stopped during the testnet
        # reset and never restarted. It stayed down 39 hours, and this sweep
        # was run in that window and reported 14 passed -- because nothing in
        # it had ever asked. A light wallet cannot read the chain itself: when
        # this is down it shows nothing, and when it is behind it shows a
        # wrong balance, which is worse.
        #
        # Both names are listed even though electrum2 is not built yet. One
        # Electrum server is a single point of failure and Komodo Wallet
        # requires two for a UTXO coin, so a red line here is the accurate
        # report of where this stands rather than a gap nothing mentions.
        set -- $NODES
        run "electrum servers answer and agree" \
            python3 scripts/check_electrum.py --node "$1" --network testnet \
            electrum.wamcoin.org electrum2.wamcoin.org

        # The pool had found 150 blocks, owed 16,176 WAM to two miners and had
        # paid nothing since genesis -- every payout failing for the whole life
        # of the chain -- while its page was green, its service active, its
        # ports open and miners happily submitting shares. This sweep was run
        # that morning and said 14 passed. A human found it by opening the
        # pool's own web page for an unrelated reason.
        #
        # So this asks the two questions nothing else did: does every stratum
        # port actually hand out a job, and have miners actually been paid.
        run "pool gives work and pays for it" \
            python3 scripts/check_pool.py --node "$1" --network testnet

        # The explorer is where a stranger goes to check us without building
        # anything. A node that is wrong is a bug; an explorer that is wrong
        # is a bug everyone reads and believes. Every economic number it
        # publishes is compared against wam-params.h using the same parser
        # verify_supply.py uses, so the page and consensus cannot drift.
        run "explorer publishes what consensus enforces" \
            python3 scripts/check_explorer.py --node "$1" --network testnet

        # v0.1.5 changed the mainnet treasury address, which is consensus. A
        # node left on v0.1.4 will reject every valid block on 15 September
        # and fork off at height 1. Its operator cannot be messaged -- the
        # protocol carries blocks, not notices -- so the only thing possible
        # is to know how many are still behind while announcing can still
        # help, rather than counting them afterwards.
        #
        # This goes red until they update, and that is the point: it is a
        # launch blocker held by other people, and the only lever is to keep
        # saying so.
        run "every independent node can follow mainnet" \
            python3 scripts/check_peer_versions.py --node "$1" --network testnet

        # The nightly backup failed on both servers every night from 23 to 26
        # August and this sweep said 21 passed on each of those mornings,
        # because nothing here had ever asked. The timer was green -- it fired
        # correctly; the service died at 03:27 into a journal nobody reads.
        #
        # A backup is the only check whose absence is invisible until the day
        # you need it, and by then asking is too late. So it is asked here,
        # every time, and the question that cannot be fooled is the age of the
        # newest file: a run can succeed and write nothing.
        run "there is something to restore from" \
            python3 scripts/check_backups.py $NODES

        # Who tried to join, and why they did not stay.
        #
        # A stranger connected three times across three days and left
        # each time, and nothing could say whether he chose to or
        # whether this node dropped him. The founder's reason for
        # wanting to know is the better one: somebody who cannot get a
        # node running does not open an issue, he closes the terminal,
        # and we never hear. If the cause is ours we fix it; if it is
        # not knowing how, it can be answered in the channels; if he
        # simply switched off, there is nothing to answer.
        #
        # It needs net logging on, and says so plainly when it is off
        # rather than reading an empty journal as nobody having come.
        run "why visitors did not stay" \
            python3 scripts/check_visitors.py --host "${NODES%% *}" --network testnet

        # Has a block that was confirmed stopped being confirmed?
        #
        # Nothing here had ever asked, and it is the one failure that costs
        # other people money rather than costing us time. A young RandomX
        # chain can be out-mined by anyone renting cloud CPUs for an hour.
        # The attack does not touch anybody's wallet: it lets the attacker
        # spend their own coins twice, against whoever accepted them on few
        # confirmations. In practice that is an exchange.
        #
        # It cannot be prevented at this size. It can be seen, and the
        # difference between hearing in four minutes and hearing in four
        # days is the difference between one lost deposit and a delisting.
        #
        # Proved on 2026-08-29 against a throwaway regtest chain rewritten
        # on purpose: seven blocks replaced, reported as seven.
        run "no confirmed block has been un-confirmed" \
            python3 scripts/check_reorg.py --network testnet \
                --state-dir "${WAM_REORG_STATE:-$HOME/.wam-reorg}" $NODES
    fi
fi

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
printf '\n%show the project looks to someone who has never heard of it%s\n' "$BLD" "$OFF"

# A Bisq maintainer read a submission for this coin and answered "I do not see
# any project related to WAM". The links were in the pull request. What he saw
# was a repository with an empty homepage field, no topics, and a description
# containing no term anyone searches for -- and a site whose links rendered
# anywhere as bare URLs. Five submissions had already gone to five venues
# before anyone looked at the front page they pointed at.
run "the project presents itself as a real one" \
    python3 scripts/check_first_impression.py

# START_HERE told beginners to download v0.1.3 for four releases after its
# binaries were deliberately withdrawn -- so the first command on the page
# written to make someone feel capable returned 404 instead. Found by the
# founder reading his own documentation, which is not a mechanism.
run "the documented version still exists" \
    python3 scripts/check_docs_version.py

# The bot is how a node operator learns that a release changes a consensus
# rule. There is no other way: the protocol carries blocks, not notices. A
# bot that has quietly stopped is indistinguishable from a quiet week, and
# the day it matters is the day nobody hears.
#
# check_bots.py existed and was not run by this sweep, which is the same
# shape of gap as the backup: a check that works, and nothing calling it.
if [ -n "$NODES" ]; then
    run "the announcer is alive and can be heard" \
        python3 scripts/check_bots.py --host "${NODES%% *}" --network testnet
else
    skip "the announcer is alive and can be heard" "no --nodes given"
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

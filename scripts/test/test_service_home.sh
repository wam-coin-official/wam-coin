#!/bin/bash
# ===========================================================================
#  test_service_home.sh -- a unit that runs wam tooling must have a HOME
# ===========================================================================
#
#      bash scripts/test/test_service_home.sh
#
#  WHY THIS EXISTS
#
#  systemd sets no HOME for a service that names no User=. Anything that
#  resolves ~ then resolves it to /, and wam-cli goes looking for its data
#  directory at /.wam. What it prints when it fails to find it is:
#
#      Could not locate RPC credentials. No authentication cookie could be
#      found, and RPC password is not set.
#
#  which reads exactly like a node that is down, while the node is up and
#  answering everything else on the machine. Every minute spent on that
#  message is spent looking at the node.
#
#  This has now happened twice.
#
#    2026-08-26  wam-backup.service. The nightly backup failed on both
#                servers for three days. Nothing noticed, because the timer
#                was green -- the timer fired perfectly; the service died
#                into a journal nobody reads. The one thing backups exist to
#                protect went unprotected while every dashboard said fine.
#
#    2026-08-29  wam-reorg-watch@.service, written by the same person, on
#                the same day he wrote the check that would have caught the
#                first one. Knowing about a trap is not a guard rail.
#
#  So this is the guard rail. It reads every unit in deploy/systemd and
#  fails if one runs wam tooling as root without setting HOME.
# ===========================================================================

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0

for unit in deploy/systemd/*.service; do
    [ -f "$unit" ] || continue

    # Only units that actually invoke our tooling can hit this. A unit that
    # runs a binary with an explicit -datadir on its command line is immune,
    # because nothing resolves ~.
    execs=$(grep -E '^\s*(ExecStart|ExecStartPre|ExecStartPost|ExecStop|ExecCondition)=' "$unit" || true)
    case "$execs" in
        *wam-cli*|*/opt/wam/scripts/*|*wamd*) ;;
        *) continue ;;
    esac

    # If every invocation names its own -datadir or -conf, HOME is never
    # consulted and the unit is fine as it is.
    needs_home=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            *wam-cli*|*/opt/wam/scripts/*|*wamd*) ;;
            *) continue ;;
        esac
        # Both spellings. wamd-mainnet.service writes "--datadir /root/..."
        # with a space and was flagged by an earlier version of this test
        # that only knew "-datadir=". A test that cries wolf once is a test
        # that gets ignored afterwards, which is worse than not having it.
        case "$line" in
            *-datadir*|*-conf*) ;;
            *) needs_home=1 ;;
        esac
    done <<< "$execs"

    [ "$needs_home" = 1 ] || continue

    # A unit that names a User= gets that user's HOME from the passwd file,
    # so only the root-by-default units are at risk.
    if grep -qE '^\s*User=' "$unit"; then
        continue
    fi

    if grep -qE '^\s*Environment=.*\bHOME=' "$unit"; then
        printf '  %sok%s    %s sets HOME\n' "$GRN" "$OFF" "$(basename "$unit")"
    else
        printf '  %sFAIL%s  %s runs wam tooling with no User= and no HOME.\n' \
            "$RED" "$OFF" "$(basename "$unit")"
        printf '        wam-cli will look in /.wam and report missing RPC\n'
        printf '        credentials, which looks like a node that is down.\n'
        printf '        Add:  Environment=HOME=/root\n'
        fails=$((fails + 1))
    fi
done

echo
if [ "$fails" -gt 0 ]; then
    printf '  %s%d unit(s) would fail at runtime for a reason nobody reads%s\n' \
        "$RED" "$fails" "$OFF"
    exit 1
fi
printf '  %severy unit that resolves ~ has a HOME to resolve it to%s\n' "$GRN" "$OFF"

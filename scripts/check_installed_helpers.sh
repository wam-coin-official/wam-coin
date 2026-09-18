#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_installed_helpers.sh -- is the script that RUNS the script we wrote?
# ===========================================================================
#
#      bash scripts/check_installed_helpers.sh HOST [HOST...]
#
#  WHY THIS EXISTS
#
#  deploy.sh updates /opt/wam on each host and stops there, which is correct:
#  it is a checkout, not an installer. But three of the files in deploy/ are
#  not read from the checkout at all. They are COPIES, installed into
#  /usr/local/bin, and that is what systemd runs:
#
#      wam-backup.sh                nightly, every host
#      wam-concentration-log.sh     hourly, the explorer host
#
#  So a change to one of them can be written, reviewed, committed, pushed,
#  deployed to all three machines and still not be running anywhere. Nothing
#  fails. The timer stays green, the service exits 0, the log keeps filling --
#  with the output of the old code.
#
#  On 18 September 2026 the concentration logger was changed to record the
#  seven-day window, the one the project's public condition is written
#  against. deploy.sh reported "every host is running <commit>". The installed
#  copy was the previous version and went on discarding the figure for another
#  hour, until the two files were hashed side by side.
#
#  This is the same shape as the pool that ran old code after a deploy because
#  nothing restarted it, and the site that stayed wrong for two days because
#  pushing to main does not publish it. Deploying is not installing, installing
#  is not restarting, and none of the three is publishing. Each of those gaps
#  gets a check rather than a habit.
#
#  WHAT IT DOES NOT COMPLAIN ABOUT
#
#  A helper that is absent. These are installed per ROLE -- the concentration
#  logger belongs on the host with the explorer and nowhere else, because
#  there is nothing for it to read anywhere else. Absent is reported as a
#  note. Present and DIFFERENT is the finding.
#
#  EXIT CODES, this project's convention
#
#      0  every installed copy matches the checkout
#      1  an installed copy differs from the checkout it was made from
#      2  no host could be read, so nothing was compared
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
FAIL=0
READ_ANY=0

# The helpers that are installed rather than run from the checkout. Not
# everything in deploy/: rotate_announce_secrets.sh and test-backup-pass.sh
# are run by hand from /opt/wam and have no installed copy to drift from.
HELPERS='wam-backup.sh wam-concentration-log.sh'

if [ $# -lt 1 ]; then
    printf 'usage: %s HOST [HOST...]\n' "${0##*/}" >&2
    exit 2
fi

rsh() {
    timeout 45 ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$1" "$2" 2>/dev/null
}

echo "=================================================================="
echo " Is the installed copy the one in deploy/?"
echo "=================================================================="

for h in "$@"; do
    printf '\n%s%s%s\n' "$BLD" "$h" "$OFF"

    # Both sides are hashed ON THE HOST, against that host's own checkout.
    # Hashing the laptop's copy instead would compare a file that CRLF and a
    # different checkout state can both change, and would report a difference
    # that exists only here.
    out="$(rsh "$h" "
        for f in $HELPERS; do
            i=/usr/local/bin/\$f
            s=/opt/wam/deploy/\$f
            if [ ! -f \"\$i\" ]; then echo \"\$f absent\"; continue; fi
            if [ ! -f \"\$s\" ]; then echo \"\$f nosource\"; continue; fi
            a=\$(sha256sum \"\$i\" | cut -d' ' -f1)
            b=\$(sha256sum \"\$s\" | cut -d' ' -f1)
            [ \"\$a\" = \"\$b\" ] && echo \"\$f same\" || echo \"\$f DIFFERENT \$a \$b\"
        done" | tr -d '\r')"

    if [ -z "$out" ]; then
        printf '  %s??%s     unreachable over ssh -- nothing was compared\n' "$YLW" "$OFF"
        continue
    fi
    READ_ANY=1

    while read -r name verdict a b; do
        [ -n "$name" ] || continue
        case "$verdict" in
            same)
                printf '  %sok%s     %s matches the checkout\n' "$GRN" "$OFF" "$name" ;;
            absent)
                printf '  %snote%s   %s is not installed here -- helpers are per role\n' \
                    "$YLW" "$OFF" "$name" ;;
            nosource)
                printf '  %s??%s     %s has no copy in /opt/wam/deploy to compare with\n' \
                    "$YLW" "$OFF" "$name" ;;
            DIFFERENT)
                printf '  %sFAIL%s   %s is INSTALLED STALE -- systemd runs the old code\n' \
                    "$RED" "$OFF" "$name"
                printf '         installed %s\n         checkout  %s\n' "${a:0:16}" "${b:0:16}"
                printf '         fix: install -m 0755 /opt/wam/deploy/%s /usr/local/bin/%s\n' \
                    "$name" "$name"
                FAIL=$((FAIL + 1)) ;;
        esac
    done <<EOF
$out
EOF
done

echo
echo "=================================================================="
if [ "$FAIL" -ne 0 ]; then
    printf ' %s%d installed helper(s) are not the code in the repository%s\n' \
        "$RED" "$FAIL" "$OFF"
    echo "=================================================================="
    exit 1
fi
if [ "$READ_ANY" -eq 0 ]; then
    printf ' %sno host answered -- nothing was compared, and this is not a pass%s\n' \
        "$YLW" "$OFF"
    echo "=================================================================="
    exit 2
fi
printf ' %severy installed helper is the code in the repository%s\n' "$GRN" "$OFF"
echo "=================================================================="
exit 0

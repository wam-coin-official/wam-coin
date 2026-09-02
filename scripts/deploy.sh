#!/bin/bash
# ===========================================================================
#  deploy.sh -- put origin/main on the servers, and prove it landed
# ===========================================================================
#
#      bash scripts/deploy.sh                       # both seeds
#      bash scripts/deploy.sh 169.58.159.165        # one of them
#
#  WHY THIS EXISTS
#
#  This is the operation performed more often than any other here, and until
#  now it was a line typed by hand into a throwaway script:
#
#      git -C /opt/wam fetch -q origin && git -C /opt/wam reset -q --hard origin/main
#
#  On 2 September 2026 that line failed on France with "could not read
#  Username for 'https://github.com'" -- git's unhelpful way of saying the ref
#  listing came back malformed. GitHub was having a bad few minutes; the same
#  command worked perfectly a quarter of an hour later.
#
#  The failure was not the problem. The problem was that the && chain stopped
#  there, the script printed "4fb9fda -> 4fb9fda", and that reads as "nothing
#  to do" rather than "this did not happen". France stayed two commits behind
#  and the only thing that noticed was check_deployed_code.sh going red on the
#  panel an hour later -- which is the safety net working, and is not a
#  substitute for the deploy telling the truth at the time.
#
#  So: retries, because the failure is transient. And the commit is READ BACK
#  from each host afterwards and compared, because a deploy that reports
#  success without checking is a deploy that will one day be wrong quietly.
# ===========================================================================

set -uo pipefail
cd "$(dirname "$0")/.."

GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'

HOSTS=("$@")
[ ${#HOSTS[@]} -gt 0 ] || HOSTS=(169.58.159.165 5.223.52.200)

TRIES=4

WANT="$(git rev-parse HEAD)"
SHORT="${WANT:0:7}"
echo
echo "${BLD}deploying $SHORT$OFF -- $(git log -1 --format=%s | cut -c1-60)"

# Refuse to deploy what has not been pushed. Otherwise the servers are reset
# to an origin/main that does not contain the change just made here, and the
# result looks like a successful deploy of the wrong thing.
if ! git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    git fetch -q origin 2>/dev/null
    if ! git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
        echo "  ${RED}HEAD is not on origin/main -- push first${OFF}"
        echo "  (the servers reset to origin/main; deploying now would deploy"
        echo "   something older than what is in this working tree)"
        echo
        exit 2
    fi
fi

bad=0
for h in "${HOSTS[@]}"; do
    before="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$h" \
        'git -C /opt/wam rev-parse --short HEAD' 2>/dev/null)"
    got=""
    for try in $(seq 1 $TRIES); do
        err="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$h" \
            'git -C /opt/wam fetch -q origin && git -C /opt/wam reset -q --hard origin/main' 2>&1)"
        rc=$?
        if [ $rc -eq 0 ]; then break; fi
        printf '  %s!!%s    %s attempt %d: %s\n' "$YEL" "$OFF" "$h" "$try" \
            "$(printf '%s' "$err" | tail -1 | cut -c1-80)"
        sleep 5
    done

    # Read it back. Not "the command exited 0" -- what the machine now holds.
    got="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$h" \
        'git -C /opt/wam rev-parse HEAD' 2>/dev/null)"

    if [ "$got" = "$WANT" ]; then
        # Scripts that run from outside the checkout have to be copied out of
        # it, or the machine runs the new code everywhere except where it
        # matters most -- wam-facts is the forced command on the reporting key.
        ssh -o BatchMode=yes "root@$h" '
            install -m 755 /opt/wam/scripts/wam-facts.sh /usr/local/bin/wam-facts
            install -m 755 /opt/wam/scripts/wam-maint.sh /usr/local/bin/wam-maint
        ' >/dev/null 2>&1
        if [ "$before" = "$SHORT" ]; then
            printf '  %sok%s    %-16s already on %s\n' "$GRN" "$OFF" "$h" "$SHORT"
        else
            printf '  %sok%s    %-16s %s -> %s\n' "$GRN" "$OFF" "$h" "${before:-?}" "$SHORT"
        fi
    else
        printf '  %sFAIL%s  %-16s is on %s, wanted %s\n' "$RED" "$OFF" "$h" \
            "${got:0:7}" "$SHORT"
        bad=1
    fi
done

echo
if [ $bad -eq 0 ]; then
    echo "  ${GRN}every host is running $SHORT${OFF}"
else
    echo "  ${RED}a host is not running this code -- it is not deployed${OFF}"
fi
echo
exit $bad

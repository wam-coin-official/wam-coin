#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_deployed_code.sh -- is the running software this software?
# ===========================================================================
#
#      bash scripts/check_deployed_code.sh HOST [HOST...]
#
#  WHY THIS EXISTS
#
#  check_nodes_agree.sh compares the node binaries, because two nodes with
#  different consensus rules split a chain. It says nothing about everything
#  else that is deployed from this repository -- the pool, the announcement
#  bot, the dashboard, the explorer -- and those drift the same way and are
#  noticed even later, because nothing they do stops.
#
#  On 2026-08-20 the checkout on the pool server was seven commits behind. One
#  of those commits fixed a release announcement arriving on Telegram with its
#  code fences showing as literal backticks. The fix was written, committed,
#  pushed and correct; the bot went on posting the old way, because nobody had
#  pulled. There was no error anywhere -- the wrong version of working software
#  produces no symptom a machine can see.
#
#  This compares the deployed checkout against origin/main, which is what a
#  reader of the repository believes is running.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

# Where a checkout is expected to live. Extra entries cost one ssh each and
# save the case where someone deploys somewhere new and forgets to say.
PATHS="/opt/wam /root/wam /root/wam-coin /opt/wam-coin"

[ $# -ge 1 ] || { printf 'usage: %s HOST [HOST...]\n' "${0##*/}" >&2; exit 2; }

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
FAIL=0

git fetch origin --quiet 2>/dev/null || true
WANT="$(git rev-parse origin/main 2>/dev/null || git rev-parse HEAD)"
WANT_SHORT="${WANT:0:12}"

echo "=================================================================="
echo " Is the deployed code this code?"
echo "=================================================================="
printf '\n  origin/main  %s  %s\n\n' "$WANT_SHORT" "$(git log -1 --format=%s "$WANT" 2>/dev/null | cut -c1-52)"

for h in "$@"; do
    printf '%s%s%s\n' "$BLD" "$h" "$OFF"
    FOUND=0
    for p in $PATHS; do
        HEAD="$(timeout 45 ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$h" \
            "[ -d $p/.git ] && git -C $p rev-parse HEAD 2>/dev/null" 2>/dev/null | tr -d '\r\n ')"
        [ -n "$HEAD" ] || continue
        FOUND=1
        if [ "$HEAD" = "$WANT" ]; then
            printf '  %sok%s      %-18s %s\n' "$GRN" "$OFF" "$p" "${HEAD:0:12}"
        else
            BEHIND="$(git rev-list --count "$HEAD..$WANT" 2>/dev/null || echo '?')"
            AHEAD="$(git rev-list --count "$WANT..$HEAD" 2>/dev/null || echo '?')"
            printf '  %sFAIL%s    %-18s %s -- %s behind, %s ahead\n' \
                "$RED" "$OFF" "$p" "${HEAD:0:12}" "$BEHIND" "$AHEAD"
            if [ "$BEHIND" != "?" ] && [ "$BEHIND" != "0" ]; then
                git log --oneline "$HEAD..$WANT" 2>/dev/null | head -5 | sed 's/^/            missing: /'
            fi
            FAIL=$((FAIL + 1))
        fi

        DIRTY="$(timeout 45 ssh -o BatchMode=yes "root@$h" \
            "git -C $p status --porcelain 2>/dev/null | grep -v '^??' | head -5" 2>/dev/null)"
        if [ -n "$DIRTY" ]; then
            printf '  %swarn%s    %s has uncommitted edits:\n' "$YLW" "$OFF" "$p"
            printf '%s\n' "$DIRTY" | sed 's/^/            /'
        fi
    done
    [ "$FOUND" = 1 ] || printf '  %snote%s    no checkout found in: %s\n' "$YLW" "$OFF" "$PATHS"
done

echo
echo "=================================================================="
if [ "$FAIL" -eq 0 ]; then
    printf ' %severy deployed checkout is origin/main%s\n' "$GRN" "$OFF"
else
    printf ' %s%d checkout(s) are not running this code%s\n' "$RED" "$FAIL" "$OFF"
fi
echo "=================================================================="
[ "$FAIL" -eq 0 ]

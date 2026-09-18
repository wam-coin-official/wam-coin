#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  ship.sh -- push and deploy are one act, because forgetting the second
#             half is not a mistake anybody stops making by trying harder
# ===========================================================================
#
#      bash scripts/ship.sh
#
#  WHY THIS EXISTS
#
#  On 18 September 2026 the ops panel showed
#
#      deployed code is origin/main    FAIL
#
#  three separate times in one day. Each time the cause was the same: a commit
#  was written, pushed, and the deploy was never run. Each time it was "fixed"
#  by running scripts/deploy.sh -- which fixes that commit and nothing else.
#  The founder named it: we keep repairing the same fault, and repairing an
#  instance of a fault is not fixing it.
#
#  The fault is not forgetfulness. It is that shipping is two commands and
#  only one of them is a habit. `git push` feels finished. It is not: the
#  servers run from a checkout, and a checkout that has not been pulled is
#  code nobody is running.
#
#  So the two are one command here, and the hook installed by
#  scripts/install_hooks.sh refuses a bare `git push` to main so that the
#  one-command path is the only path. Neither is a reminder. A reminder is
#  what failed three times.
#
#  WHAT IT DOES NOT DO
#
#  It does not restart a service, install a binary, or publish the site.
#  Those are three further gaps with their own checks, and rolling them in
#  here would make one command that quietly does four dangerous things.
#  Deploying is not installing, installing is not restarting, and none of the
#  three is publishing.
#
#  EXIT CODES, this project's convention
#
#      0  pushed, deployed, and every host verified to be running it
#      1  pushed but a host is not running it -- say so, loudly
#      2  nothing was pushed
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$HERE"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# A dirty tree means the thing about to reach three servers is not the thing
# on this screen.
if [ -n "$(git status --porcelain)" ]; then
    printf '%suncommitted changes -- commit them or stash them first%s\n\n' \
        "$RED" "$OFF"
    git status --short
    echo
    exit 2
fi

printf '\n%sshipping %s%s\n' "$BLD" "$BRANCH" "$OFF"
printf '  %s\n\n' "$(git log --oneline -1)"

# WAM_SHIP is what the pre-push hook looks for. Exported here and nowhere
# else, so a bare `git push` in a terminal cannot carry it by accident.
if ! WAM_SHIP=1 git push origin "$BRANCH"; then
    printf '\n%sthe push failed -- nothing was deployed%s\n\n' "$RED" "$OFF"
    exit 2
fi

printf '\n%sdeploying%s\n' "$BLD" "$OFF"
bash scripts/deploy.sh
rc=$?

if [ "$rc" -ne 0 ]; then
    printf '%spushed, but a host is NOT running it. It is not deployed.%s\n\n' \
        "$RED" "$OFF"
    exit 1
fi

# Measured, not assumed: deploy.sh reports what it did, and this asks the
# hosts afterwards what they actually hold.
printf '\n%sverifying from the hosts%s\n' "$BLD" "$OFF"
bash scripts/check_deployed_code.sh 169.58.159.165 5.223.52.200 13.140.33.187 \
    | tail -4
exit "${PIPESTATUS[0]}"

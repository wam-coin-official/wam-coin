#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  ci_annotate_failure.sh -- put the reason where it can be read without a token
# ===========================================================================
#
#      bash scripts/ci_annotate_failure.sh <log-file> "<what was being done>"
#
#  WHY THIS EXISTS
#
#  On 7 September the first run of platform-build.yml failed on both Windows
#  and macOS, and the reason was unreadable. GitHub serves job logs and build
#  artifacts only to an authenticated caller -- both endpoints answer 403
#  anonymously -- so a failure said
#
#      Process completed with exit code 1.
#
#  and nothing more, while the error the script had printed perfectly well sat
#  behind a login. That turns every iteration into a request to somebody with
#  a browser, and a diagnosis nobody can read is not a diagnosis.
#
#  Workflow commands are the way out. `::error::` becomes a check-run
#  annotation, and the annotations endpoint IS served without a token:
#
#      /check-runs/<id>/annotations   ->  200 anonymously
#      /actions/jobs/<id>/logs        ->  403 anonymously
#
#  Measured on this repository's own failed job, not assumed.
#
#  WHAT IT HAS TO ENCODE
#
#  An annotation is one line. A newline inside it truncates the message, so
#  they are sent as %0A, and any literal % in the log has to become %25 first
#  or the encoding eats it. The order matters: % before the newlines.
# ===========================================================================

set -uo pipefail

LOG="${1:-}"
DOING="${2:-the build}"
LINES="${CI_ANNOTATE_LINES:-40}"

if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
    # Still an annotation. "There was no log" is itself the finding, and
    # saying nothing here would reproduce exactly the silence this fixes.
    printf '::error title=%s failed::no log file at %s -- the step produced no output to explain itself\n' \
        "$DOING" "${LOG:-<none given>}"
    exit 0
fi

# Blank lines and the shell's own xtrace add nothing to an annotation that has
# a length limit.
TAIL="$(grep -v '^[[:space:]]*$' "$LOG" | tail -n "$LINES")"

if [ -z "$TAIL" ]; then
    printf '::error title=%s failed::%s exists but is empty\n' "$DOING" "$LOG"
    exit 0
fi

# %25 first: doing it after the newlines would turn every %0A into %250A.
ENCODED="$(printf '%s' "$TAIL" \
    | sed 's/%/%25/g' \
    | sed 's/\r/%0D/g' \
    | awk '{ printf "%s%%0A", $0 }')"

printf '::error title=%s failed::%s\n' "$DOING" "$ENCODED"

# And to the step log as well, for whoever DOES have a token -- the annotation
# is capped and the log is not.
printf '\n----- last %s lines -----\n%s\n' "$LINES" "$TAIL"

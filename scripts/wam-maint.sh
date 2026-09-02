#!/bin/bash
# ===========================================================================
#  wam-maint.sh -- say "this next hour is us", without silencing anything
# ===========================================================================
#
#      wam-maint on 30m "kernel upgrade and reboot"
#      wam-maint status
#      wam-maint off
#
#  IT DOES NOT SUPPRESS ALARMS. NOTHING HERE CAN.
#
#  Rebooting both servers on 2 September 2026 raised two perfectly correct
#  alarms: a check that could not reach a node that had been stopped on
#  purpose, and a machine whose ports "were closed before" because it had just
#  come back. Both true, both ours. The obvious fix was a window that silences
#  alarms during planned work.
#
#  The founder refused it, and his reason is the one that matters: a switch
#  that turns the alarms off is the first thing an intruder would reach for,
#  and an intrusion that happened to land inside a window we had opened
#  ourselves would arrive as silence. He knows when he is doing maintenance.
#  He cannot know when somebody else is.
#
#  So a window answers "was this expected?" and never "should this be sent?".
#  Every alarm still leaves the machine, with a line at the top saying planned
#  work is in progress and what it is. What that buys is not quiet -- it is
#  being able to see, in the same message, which alarms were ours and which
#  were not.
#
#  The window carries an absolute expiry and closes itself. A forgotten one
#  stops labelling rather than going on to mislabel a real fault as routine.
# ===========================================================================

set -uo pipefail

STATE=/var/lib/wam-login-watch/maintenance.json
MAX_SECONDS=14400          # four hours. A window longer than this is not
                           # maintenance, it is a habit.

GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'

usage() {
    sed -n '4,8p' "$0" | sed 's/^#  \{0,1\}//'
    exit 2
}

now=$(date +%s)

case "${1:-status}" in
  on)
    dur="${2:-}"; reason="${3:-unspecified}"
    [ -n "$dur" ] || usage
    case "$dur" in
      *m) secs=$(( ${dur%m} * 60 )) ;;
      *h) secs=$(( ${dur%h} * 3600 )) ;;
      *)  secs="$dur" ;;
    esac
    if ! [ "$secs" -gt 0 ] 2>/dev/null; then
        echo "  duration must look like 30m or 2h" >&2; exit 2
    fi
    if [ "$secs" -gt "$MAX_SECONDS" ]; then
        echo "  ${YEL}capped at 4h${OFF} -- a longer window is not maintenance"
        secs=$MAX_SECONDS
    fi
    mkdir -p "$(dirname "$STATE")"
    printf '{"until": %s, "started": %s, "reason": "%s", "host": "%s"}\n' \
        "$(( now + secs ))" "$now" \
        "$(printf '%s' "$reason" | tr -d '"\\' | cut -c1-120)" \
        "$(cat /etc/hostname 2>/dev/null)" > "$STATE"
    echo "  ${GRN}labelling on${OFF} for $(( secs / 60 )) minutes -- \"$reason\""
    echo "  Alarms are NOT silenced. Every one still arrives, marked as"
    echo "  planned work so you can tell ours from anybody else's."
    ;;

  off)
    rm -f "$STATE"
    echo "  ${GRN}labelling off${OFF}"
    ;;

  status)
    if [ ! -f "$STATE" ]; then
        echo "  no planned work declared"
        exit 0
    fi
    until_ts=$(grep -oE '"until": *[0-9]+' "$STATE" | grep -oE '[0-9]+')
    reason=$(sed -E 's/.*"reason": *"([^"]*)".*/\1/' "$STATE")
    if [ "$now" -ge "${until_ts:-0}" ]; then
        echo "  a window was declared and has expired -- \"$reason\""
        echo "  (expired windows label nothing; this file is harmless)"
    else
        echo "  ${BLD}planned work declared${OFF}: \"$reason\""
        echo "  $(( (until_ts - now) / 60 )) minute(s) left"
        echo "  alarms are still being sent, and are being labelled"
    fi
    ;;

  *) usage ;;
esac

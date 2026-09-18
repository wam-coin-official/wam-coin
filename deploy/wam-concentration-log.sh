#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  wam-concentration-log.sh -- one line an hour, so the trend is a fact
# ===========================================================================
#
#  The explorer publishes how concentrated the hash rate is RIGHT NOW. That
#  number moves: it read 97.5% at block 79, 91.7% at 106 and 93.8% at 137,
#  and each of those is true. A single reading taken at four in the morning
#  by a tired person is not evidence of anything, in either direction.
#
#  So one line an hour is appended here, and after a few days the question
#  "is this getting better or not" has an answer that does not depend on when
#  anybody happened to look.
#
#  It writes to a file and nothing else. It publishes nothing, serves
#  nothing, and sends nothing anywhere -- the live figure is already public
#  at /api/concentration, and what is recorded here is that same figure with
#  a timestamp on it.
#
#  BOTH WINDOWS, because the published condition is written against the long
#  one. For its first day this recorded only the 47-block window -- the one
#  that swung between 38% and 62% in fourteen consecutive hourly readings.
#  The seven-day figure was in the same reply and was thrown away. So the
#  permanent record was of the noisy number, and the number that decides
#  whether this project applies to an exchange was not being kept at all. The
#  day somebody asks "when did it fall below 50%" there has to be a file that
#  answers.
# ===========================================================================

set -uo pipefail

OUT="${WAM_CONC_LOG:-/var/lib/wam-concentration/history.jsonl}"
URL="${WAM_CONC_URL:-http://127.0.0.1:8081/api/concentration}"

mkdir -p "$(dirname "$OUT")"

BODY="$(curl -fsS -m 25 "$URL" 2>/dev/null)"
if [ -z "$BODY" ]; then
    # A reading that did not happen is not a reading of zero. Nothing is
    # written, and the gap in the file is the honest record of the gap.
    printf 'could not read %s\n' "$URL" >&2
    exit 2
fi

printf '%s\n' "$BODY" | python3 -c '
import json, sys, time
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("unreadable reply: %s" % e, file=sys.stderr)
    raise SystemExit(2)
if not d.get("blocksRead"):
    print("the window has no blocks read yet; nothing recorded", file=sys.stderr)
    raise SystemExit(2)
def window(w):
    """The recorded shape of one window, or None when it read nothing.

    None rather than zero: a window with no blocks read is a question that
    was not asked, and a 0 in this file would later be read as a chain with
    no concentration at all.
    """
    if not w or not w.get("blocksRead") or w.get("topPercent") is None:
        return None
    return {
        "blocksRead": w.get("blocksRead"),
        "distinct": w.get("distinct"),
        "topPercent": round(w["topPercent"], 2),
        "complete": w.get("complete"),
        "top": [{"finder": t["finder"], "blocks": t["blocks"],
                 "percent": round(t["percent"], 2)} for t in w.get("top", [])],
    }

print(json.dumps({
    "t": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "tip": d.get("tip"),
    # The short window stays at the top level exactly as it was, so the lines
    # written before this change and the lines written after it can be read
    # by the same parser.
    "blocksRead": d.get("blocksRead"),
    "distinct": d.get("distinct"),
    "topPercent": round(d.get("topPercent"), 2),
    "top": [{"finder": t["finder"], "blocks": t["blocks"],
             "percent": round(t["percent"], 2)} for t in d.get("top", [])],
    "sevenDay": window(d.get("sevenDay")),
}, separators=(",", ":")))
' >> "$OUT" || exit 2

exit 0

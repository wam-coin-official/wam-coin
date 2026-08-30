#!/bin/bash
# ===========================================================================
#  make_submission.sh -- build the four files exactly as Komodo expects them
# ===========================================================================
#
#      bash integration/komodo/make_submission.sh [OUTDIR]
#
#  Three of the four files are new and can simply be copied. The fourth,
#  `coins`, is an existing file with 782 entries in it, and ours has to go
#  inside the array. Hand-editing a file that size at midnight is how a
#  misplaced comma turns a submission into a broken JSON file and a review
#  comment -- so this appends it textually, byte for byte in their own
#  formatting, and then proves the result:
#
#    * it parses as JSON
#    * it has exactly one more entry than theirs
#    * every entry that was there before is unchanged
#    * the diff against their file is only our lines
#
#  It downloads their current file each time rather than keeping a copy,
#  because a copy taken last week is a merge conflict waiting to happen.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$HERE/submission}"

# Which coins repository to build against.
#
# Komodo's own documentation points at KomodoPlatform/coins, and that is
# where #21 was sent on 2026-08-29. That repository has not moved since
# 2025-12-05, and its last commit was a merge FROM GLEECBTC -- it is a
# downstream mirror whose sync stopped nine months ago. Pull requests sit
# open there since February.
#
# GLEECBTC/coins is where the work happens: a bot updates it daily, cipig
# and shamardy -- Komodo's own people -- merge there, and new coins go in.
# Blockzero settles it. The same author sent it to both repositories on 13
# and 15 August; GLEEC merged in two days, KomodoPlatform is still open
# seventeen days later.
#
# The pull request number was the tell, and the founder saw it before I did:
# #21 against a registry of 782 coins, when the live one is at #1974.
REPO_SLUG="${WAM_COINS_REPO:-GLEECBTC/coins}"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; }
fail() { printf '  %sfail%s  %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

printf '%sbuilding the Komodo submission%s\n' "$BLD" "$OFF"

# Refuse to build a submission whose fields disagree with the source. The
# entry is read by software: a wrong pubtype does not look wrong, it sends
# somebody's coins nowhere.
python3 "$REPO/scripts/check_listing_entry.py" >/dev/null 2>&1 \
    || fail "check_listing_entry.py is failing -- fix that before submitting anything"
ok "every field still matches src/wam"

rm -rf "$OUT"
mkdir -p "$OUT/electrums" "$OUT/explorers" "$OUT/icons"

cp "$HERE/electrums-WAM.json"  "$OUT/electrums/WAM"
cp "$HERE/explorers-WAM.json"  "$OUT/explorers/WAM"
cp "$REPO/brand/png/wam-platform-128.png" "$OUT/icons/wam.png"
ok "electrums/WAM, explorers/WAM, icons/wam.png"

THEIRS="$OUT/.coins-upstream"
curl -fsS --max-time 60 \
    "https://raw.githubusercontent.com/$REPO_SLUG/master/coins" \
    -o "$THEIRS" || fail "could not download the coins file from $REPO_SLUG"
ok "downloaded $REPO_SLUG ($(wc -c < "$THEIRS") bytes)"

python3 - "$HERE/coin-entry.json" "$THEIRS" "$OUT/coins" <<'PY'
import json, sys

entry_path, theirs_path, out_path = sys.argv[1:4]

entry = json.load(open(entry_path, encoding="utf-8"))
if isinstance(entry, list):
    entry = entry[0]

text = open(theirs_path, encoding="utf-8").read()
before = json.loads(text)

if any(c.get("coin") == entry["coin"] for c in before):
    sys.exit(f"    {entry['coin']} is already in their file -- nothing to submit")

# Textual insertion, not a re-dump. Re-serialising 782 entries would rewrite
# every line of their file and the diff would be unreadable; this changes
# only the lines we add.
close = text.rstrip()
if not close.endswith("]"):
    sys.exit("    their file does not end with ] -- the format changed")
cut = text.rstrip().rfind("]")
head = text[:cut].rstrip()          # ends at the last entry's closing brace

# Their indentation: entries at two spaces, fields at four.
block = json.dumps(entry, indent=2, ensure_ascii=False)
block = "\n".join("  " + line for line in block.splitlines())

open(out_path, "w", encoding="utf-8", newline="\n").write(
    head + ",\n" + block + "\n]\n")

after = json.loads(open(out_path, encoding="utf-8").read())
if len(after) != len(before) + 1:
    sys.exit(f"    expected {len(before)+1} entries, got {len(after)}")
if after[:-1] != before:
    sys.exit("    an existing entry changed -- refusing to submit this")
if after[-1] != entry:
    sys.exit("    the appended entry is not the one we wrote")
print(f"    {len(before)} entries in, {len(after)} out, only ours added")
PY
[ $? -eq 0 ] || fail "building coins failed"
ok "coins built and verified"

ADDED=$(diff "$THEIRS" "$OUT/coins" | grep -c '^>')
REMOVED=$(diff "$THEIRS" "$OUT/coins" | grep -c '^<')
printf '  %sok%s    the diff is %s line(s) added, %s removed\n' "$GRN" "$OFF" "$ADDED" "$REMOVED"
[ "$REMOVED" -le 1 ] || fail "the diff removes $REMOVED lines -- it should remove at most the closing bracket"

rm -f "$THEIRS"

cat <<EOF

  Ready in: $OUT

    coins            replace theirs with this one
    electrums/WAM    new file
    explorers/WAM    new file
    icons/wam.png    new file

  Copy all four into a fork of $REPO_SLUG, keeping the paths, then open the
  pull request. The title and body are in $HERE/SUBMIT.md.

EOF

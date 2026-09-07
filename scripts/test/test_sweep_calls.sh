#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  A comment after a backslash comments out the command
# ===========================================================================
#
#      bash scripts/test/test_sweep_calls.sh
#
#  WHAT HAPPENED
#
#  scripts/sweep.sh contained this:
#
#      run "a new node can sync from genesis" \
#          # 300, not 120. A new node builds a RandomX verification context
#          ...
#          bash scripts/check_fresh_sync.sh --network testnet ...
#
#  A backslash at the end of a line joins the next line to it. The next line
#  was a comment, so everything from the `#` onward -- including the command
#  three lines down -- was commented out. `run` was called with a label and no
#  command at all.
#
#  An empty command runs nothing and exits 0. So the panel printed
#
#      a new node can sync from genesis   ok
#
#  for a check the sweep never evaluated, while the real script ran underneath
#  as a separate top-level command with its exit status thrown away. It was
#  exiting 2 -- "no wamd found" -- and that never reached the panel. The one
#  check that asks whether a stranger can validate this chain from genesis was
#  the check that was not running.
#
#  Nothing about this is visible when reading the file. The indentation makes
#  the command look like an argument, `bash -n` accepts it, and shellcheck
#  does not flag it either. It is a syntax trap, so it needs a mechanical
#  check rather than more care.
#
#  run() now refuses an empty command, which catches the consequence. This
#  catches the cause, everywhere, including in scripts that have no harness to
#  notice.
# ===========================================================================

set -uo pipefail
cd "$(dirname "$0")/../.."

# This check matches text, so it honours the project's quotation marks like
# every other one that does -- scripts/lib/quoted.sh, enforced by
# scripts/check_mentions.py. Its own header quotes the bad pattern in order to
# explain it, which is exactly the case the marks exist for: the first run of
# this script reported itself.
. "$(cd "$(dirname "$0")/../lib" && pwd)/quoted.sh"

GRN=$'\033[32m'; RED=$'\033[31m'; BLD=$'\033[1m'; OFF=$'\033[0m'
fails=0
scanned=0

echo
echo "${BLD}no command is hidden behind a continued line${OFF}"

# Every tracked shell script, asked of git rather than found by globbing, so
# a new directory is covered without this being edited.
while IFS= read -r f; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))

    # awk, not grep: the question is about a line and the one after it, and
    # grep answers about single lines. `prev` holds the previous line.
    # awk, not grep: the question is about a line and the one after it, and
    # grep answers about single lines.
    #
    # The second condition is what makes this usable. A backslash at the end
    # of a COMMENT line continues nothing -- the whole line is already a
    # comment -- and every header in this project ends usage examples that
    # way:
    #
    #     #      bash scripts/check_fresh_sync.sh --network testnet \
    #     #          --binary /path/to/wamd
    #
    # Without it, the first run reported four files and all four were usage
    # examples. A check that cries wolf on documentation is a check people
    # switch off.
    hits="$(unquoted "$f" | awk '
        prev ~ /\\[[:space:]]*$/ && prev !~ /^[[:space:]]*#/ && $0 ~ /^[[:space:]]*#/ {
            printf "%d: %s\n", NR, $0
        }
        { prev = $0 }
    ')"

    if [ -n "$hits" ]; then
        printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$f"
        printf '%s\n' "$hits" | head -3 | sed 's/^/          /'
        printf '        The line above each of these ends in "\\", so this\n'
        printf '        comment and everything after it is commented out.\n'
        fails=$((fails + 1))
    fi
done <<EOF
$(git ls-files '*.sh' 2>/dev/null)
EOF

echo
if [ "$scanned" -eq 0 ]; then
    printf '  %sno script was scanned -- this proves nothing%s\n\n' "$RED" "$OFF"
    exit 2
fi

if [ "$fails" -eq 0 ]; then
    printf '  %sok%s    %d shell script(s): no comment sits on a continued line\n' \
        "$GRN" "$OFF" "$scanned"
    echo
    exit 0
fi

printf '  %s%d file(s) hide a command behind a comment%s\n' "$RED" "$fails" "$OFF"
echo
echo '  Move the comment ABOVE the command it explains. The backslash must be'
echo '  followed by the continuation, not by a comment.'
echo
exit 1

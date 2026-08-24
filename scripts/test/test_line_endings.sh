#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  test_line_endings.sh -- no tracked text file carries a carriage return
# ===========================================================================
#
#      bash scripts/test/test_line_endings.sh
#
#  WHY THIS EXISTS
#
#  .gitattributes says every text file is stored with LF. This is the part
#  that finds out whether that is true, because a rule nothing checks is a
#  preference.
#
#  CRLF gets in from the Windows side of this project and it does not
#  announce itself. It has cost this repository three times:
#
#    - shell scripts copied to the servers failed to run
#    - a thirty-line change to the miner arrived as a 1097-line diff, which
#      is a change nobody can review
#    - scripts/gen_founder_key.py -- the founder key ceremony, run once,
#      from a live USB, by one person with no second chance -- carried a
#      shebang ending in a carriage return. `./scripts/gen_founder_key.py`
#      answers "bad interpreter" and says nothing about why
#
#  The last one is why this is a test and not a lint. A script with a broken
#  shebang is worse than a missing script: it looks present.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$HERE"

RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'

dirty=0
shebang_dirty=0

while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue

    # Ask git what it considers binary rather than guessing by extension:
    # a file with a NUL byte in the first 8000 is binary to git, and that
    # is the same rule .gitattributes' `text=auto` applies.
    if git check-attr binary -- "$f" | grep -q ': binary: set$'; then
        continue
    fi
    if LC_ALL=C grep -qI . "$f" 2>/dev/null; then :; else continue; fi

    cr=$(tr -cd '\r' < "$f" | wc -c)
    [ "$cr" -eq 0 ] && continue

    dirty=$((dirty + 1))
    if head -c 2 "$f" 2>/dev/null | grep -q '#!'; then
        shebang_dirty=$((shebang_dirty + 1))
        printf '  %sFAIL%s %-46s CR=%-5s  and it has a shebang: this file will not run\n' \
            "$RED" "$OFF" "$f" "$cr"
    else
        printf '  %sFAIL%s %-46s CR=%s\n' "$RED" "$OFF" "$f" "$cr"
    fi
done < <(git ls-files -z)

if [ "$dirty" -eq 0 ]; then
    printf '  %sok%s  every tracked text file uses LF\n' "$GRN" "$OFF"
    exit 0
fi

echo
printf '  %d file(s) carry CRLF' "$dirty"
[ "$shebang_dirty" -gt 0 ] && printf ', %d of them executable scripts' "$shebang_dirty"
echo '.'
echo
echo '  fix, from the repository root:'
echo
echo "    git ls-files -z | xargs -0 sed -i 's/\r\$//'"
echo
echo '  then commit. .gitattributes keeps them that way afterwards.'
exit 1

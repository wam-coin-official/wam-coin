#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  test_exec_bits.sh -- every shebang file must be executable in git
# ===========================================================================
#
#      bash scripts/test/test_exec_bits.sh
#
#  The repository is developed on a Windows filesystem, which has no
#  executable bit. Git therefore records new scripts as 100644 unless told
#  otherwise, and nothing local ever notices: on the Windows mount every file
#  reads as rwxrwxrwx, so `./install.sh` works on the machine it was written
#  on and fails for everyone who clones it.
#
#  The README's first instruction is `./install.sh --network regtest`. It
#  returned "Permission denied" for every stranger who tried the project,
#  which is the worst possible first impression: not a bug in the code, but
#  proof that nobody had ever run the quick-start as written.
#
#  Found by deploying to a real server, thirty-five days before launch.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$HERE"

GREEN=$'\033[32m'; RED=$'\033[31m'; OFF=$'\033[0m'
BAD=0
COUNT=0

while IFS= read -r f; do
    [ -f "$f" ] || continue
    # A shebang is the file declaring itself directly runnable.
    head -c2 "$f" 2>/dev/null | grep -q '#!' || continue
    COUNT=$((COUNT + 1))
    MODE="$(git ls-files -s -- "$f" | awk '{print $1}')"
    if [ "$MODE" != "100755" ]; then
        printf '  %sFAIL%s  %s is %s, not 100755\n' "$RED" "$OFF" "$f" "$MODE"
        BAD=$((BAD + 1))
    fi
done < <(git ls-files)

echo
if [ "$BAD" -eq 0 ]; then
    printf '  %sok%s    all %d shebang files are executable in the index\n' \
        "$GREEN" "$OFF" "$COUNT"
else
    printf '  %d of %d shebang files are not executable.\n\n' "$BAD" "$COUNT"
    printf '  Fix:  git update-index --chmod=+x <file>\n'
    exit 1
fi

# The one the README tells a stranger to type first.
if [ "$(git ls-files -s -- install.sh | awk '{print $1}')" = "100755" ]; then
    printf '  %sok%s    install.sh, the first command in the README, is runnable\n' \
        "$GREEN" "$OFF"
else
    printf '  %sFAIL%s  install.sh is not executable\n' "$RED" "$OFF"
    exit 1
fi

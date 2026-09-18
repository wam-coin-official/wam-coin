#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  install_hooks.sh -- point git at the hooks this repository carries
# ===========================================================================
#
#      bash scripts/install_hooks.sh
#
#  .git/hooks is not tracked by git, so a hook committed to a repository does
#  nothing until somebody wires it up. core.hooksPath does that in one setting
#  and keeps the hooks themselves in the tree, where they are reviewed and
#  versioned like everything else -- rather than copies in .git that drift
#  silently and vanish on a fresh clone.
#
#  Run it once per clone. It is safe to run again.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$HERE"

GRN=$'\033[32m'; YLW=$'\033[33m'; OFF=$'\033[0m'

current="$(git config --get core.hooksPath || true)"
if [ "$current" = "scripts/hooks" ]; then
    printf '  %sok%s    core.hooksPath is already scripts/hooks\n' "$GRN" "$OFF"
else
    git config core.hooksPath scripts/hooks
    printf '  %sok%s    core.hooksPath -> scripts/hooks%s\n' "$GRN" "$OFF" \
        "${current:+  (was $current)}"
fi

# The executable bit matters on Linux and is meaningless on Windows, where git
# runs the hook through the shell regardless. Set it in the index so a clone
# on a server gets a hook it can actually run.
for h in scripts/hooks/*; do
    [ -f "$h" ] || continue
    chmod +x "$h" 2>/dev/null
    mode="$(git ls-files -s "$h" | awk '{print $1}')"
    if [ "$mode" = "100755" ]; then
        printf '  %sok%s    %s is executable in the index\n' "$GRN" "$OFF" "$h"
    else
        printf '  %s!!%s    %s is %s in the index -- run:\n' "$YLW" "$OFF" "$h" "$mode"
        printf '          git update-index --chmod=+x %s\n' "$h"
    fi
done

printf '\n  Hooks installed:\n'
for h in scripts/hooks/*; do
    [ -f "$h" ] || continue
    printf '    %-14s %s\n' "$(basename "$h")" \
        "$(sed -n '6s/^#  [a-z-]* -- //p' "$h")"
done
echo

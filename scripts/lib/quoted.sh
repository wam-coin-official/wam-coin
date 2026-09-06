#!/bin/bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  quoted.sh -- the shell twin of scripts/lib/quoted.py
# ===========================================================================
#
#      . "$SCRIPTS_DIR/lib/quoted.sh"
#      unquoted path/to/file | grep -n 'TODO'
#
#  Same marks, same meaning, one convention: text that mentions a thing is not
#  the thing. The reasoning is in quoted.py; it is not repeated here, because
#  two copies of a reason drift exactly the way two copies of a file list did.
#
#  `unquoted` prints the file with every quoted line blanked and the line
#  COUNT preserved, so `grep -n` still reports the real line number.
# ===========================================================================

# shellcheck disable=SC2148

unquoted() {
    awk '
        /wam:quote-begin/ { inside = 1; print ""; next }
        /wam:quote-end/   { inside = 0; print ""; next }
        /wam:quote-line/  { print ""; next }
        inside            { print ""; next }
                          { print }
    ' "$@"
}

# For the many callers that want "does this file contain X, ignoring
# quotations" without building a pipeline each time.
#   grep_unquoted -E 'TODO|FIXME' file...
grep_unquoted() {
    local last="${!#}"
    local args=("${@:1:$#-1}")
    unquoted "$last" | grep "${args[@]}"
}

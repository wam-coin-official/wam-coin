# shellcheck shell=bash
# ===========================================================================
#  lib/python.sh -- find an interpreter that is actually Python
# ===========================================================================
#
#      . "$(dirname "$0")/lib/python.sh"
#      "$PY" scripts/check_channels.py
#
#  WHY THIS EXISTS
#
#  On 5 September 2026 the operations dashboard reported that the repository
#  disagreed with itself, and named the vesting schedule -- a consensus value.
#  It did not. scripts/check_vesting_sync.py printed all five tranches from
#  all three sources, identical, and said so.
#
#  audit_repo.sh decides that check by running
#
#      python3 scripts/check_vesting_sync.py
#
#  and reading the exit code. On this machine `python3` resolves to
#
#      C:\Users\...\AppData\Local\Microsoft\WindowsApps\python3
#
#  which is the Microsoft Store's installer stub. It prints nothing, runs
#  nothing, and exits 49 for everything -- the same shape of trap as the WSL
#  `bash` stub that made the signing script appear to do nothing earlier the
#  same day.
#
#  So every Python check invoked from a shell script was dead on Windows:
#  twenty of them, across fifteen scripts, including most of sweep.sh. They
#  passed on the Linux servers, where python3 is real, which is exactly why
#  nobody had noticed. A safety net that is whole on one machine and absent on
#  the machine it is actually run from is worse than none, because the green
#  is believed.
#
#  IF BASH READS PYTHON'S OUTPUT, PYTHON MUST BE TOLD TO EMIT LF
#
#  On Windows, Python's stdout is a text stream and translates every \n into
#  \r\n. Shell substitution strips a trailing newline; it does not strip a
#  carriage return. So a value read out of a Python snippet arrives with an
#  invisible \r glued to the end of it.
#
#  check_release_matches.sh built a download URL that way, and curl was asked
#  for
#
#      .../wam-coin-v0.1.6-x86_64-linux-gnu.tar.gz\r
#
#  which does not exist. The check reported that the published release could
#  not be downloaded -- while the same curl, run by hand, fetched all
#  11,749,026 bytes in eight seconds.
#
#  No interpreter flag prevents this. -u does not, and neither does
#  PYTHONLEGACYWINDOWSSTDIO; both were measured. The snippet has to say so
#  itself, as its first statement:
#
#      import sys; sys.stdout.reconfigure(newline='\n')
#
#  or write bytes with sys.stdout.buffer.write(). Anything else hands the
#  shell a value that is one character longer than it looks.
#
#  WHY IT VERIFIES INSTEAD OF LOOKING
#
#  `command -v python3` finds the stub. So does `test -x`. The only way to
#  know an interpreter is an interpreter is to make it prove it, which is what
#  the probe below does. Anything that cannot import sys and print its own
#  version is not Python, whatever its name.
# ===========================================================================

_wam_is_python() {
    # A real interpreter answers with its version on stdout and exits 0.
    # The Store stub prints nothing and exits 49.
    local out
    out="$("$@" -c 'import sys; sys.stdout.write("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || return 1
    case "$out" in
        3.*) return 0 ;;
        *)   return 1 ;;
    esac
}

PY=""
for _wam_candidate in python3 python py; do
    if command -v "$_wam_candidate" >/dev/null 2>&1 \
       && _wam_is_python "$_wam_candidate"; then
        PY="$_wam_candidate"
        break
    fi
done
unset _wam_candidate

if [ -z "$PY" ]; then
    echo "error: no working Python 3 found." >&2
    echo "       Tried python3, python and py; each was missing or was a stub" >&2
    echo "       that does not run code. On Windows the Microsoft Store" >&2
    echo "       placeholder in WindowsApps answers to python3 and exits 49." >&2
    echo "       Install Python 3, or put the real one earlier on PATH." >&2
    return 2 2>/dev/null || exit 2
fi

export PY

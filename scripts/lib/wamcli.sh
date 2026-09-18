# shellcheck shell=bash
# ===========================================================================
#  lib/wamcli.sh -- how a shell script addresses one chain with wam-cli
# ===========================================================================
#
#      . "$SCRIPTS_DIR/lib/python.sh"      # must come first, sets $PY
#      . "$SCRIPTS_DIR/lib/wamcli.sh"
#      CLI="wam-cli $(wam_cli_flags mainnet)"
#
#  WHY THIS EXISTS
#
#  wamcli.py was written on 4 September 2026 after six Python checks were
#  found asking the testnet node about mainnet. It fixed the six and nothing
#  else, because at the time nothing else needed it.
#
#  The shell scripts kept writing `wam-cli` bare. On a server the default
#  datadir is /root/.wam, whose wam.conf says testnet=1, so bare `wam-cli` is
#  the TESTNET node -- always, silently, with no flag to notice the absence
#  of. On 18 September 2026, three days into mainnet, check_nodes_agree.sh
#  reported
#
#      comparing at height 9964 ... one chain | all 3 nodes agree
#
#  while mainnet was at height 2382. It had compared three testnet nodes and
#  printed a green line about them. The one check whose entire purpose is to
#  catch a consensus split had been examining a chain nobody uses, and the
#  sweep counted it as a pass.
#
#  A second copy of the flags in bash would have drifted from the Python one
#  the first time either changed. So this does not carry a copy: it asks
#  wamcli.py, which stays the only place the answer is written down.
#
#  newline='\n' is not optional. Python on Windows translates \n to \r\n on
#  the way out, shell substitution strips the newline and not the carriage
#  return, and the \r would be glued into the middle of an ssh command line.
# ===========================================================================

_WAM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# wam_cli_flags NETWORK -> the flags, on stdout, with no trailing newline.
#
# An unknown network is wamcli.py's ValueError, not a silently empty string:
# empty flags are exactly the bug this file exists to end.
wam_cli_flags() {
    local net="${1:?wam_cli_flags needs a network}"
    "${PY:-python3}" -c '
import sys
sys.stdout.reconfigure(newline="\n")
sys.path.insert(0, sys.argv[1])
from wamcli import flags
sys.stdout.write(flags(sys.argv[2]))
' "$(dirname "$_WAM_LIB_DIR")" "$net"
}

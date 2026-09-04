#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  preflight.sh -- is this actually ready to launch?
# ===========================================================================
#
#      bash scripts/preflight.sh                     # local checks only
#      bash scripts/preflight.sh --host IP           # also check a server
#      bash scripts/preflight.sh --nodes "IP1 IP2"   # also compare nodes
#                                                     against each other
#
#  WHY THIS EXISTS
#
#  Every "full system check" up to now reported that things were running, and
#  running is not the same as correct. `systemctl is-active wamd` said active
#  while the executable was still called bitcoind and wamd was a symlink
#  beside it. A check that asks "is the service up" cannot see that.
#
#  So this asks the questions whose answers only appear when you try to use
#  the thing: can a release be packaged, is the binary named ours, does the
#  config the node reads exist under our name, would a stranger's first
#  command work. Each check names what breaks if it fails, because a red line
#  with no consequence attached gets ignored.
#
#  It is meant to fail. Items 1 and 2 below cannot pass before the key
#  ceremony, and that is correct -- they are the gate, not a defect.
# ===========================================================================

set -uo pipefail

# An interpreter that is actually Python: `python3` on Windows is a
# Microsoft Store stub that runs nothing and exits 49.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPTS_DIR/lib/python.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

HOST=""
NODES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host)  HOST="$2";  shift 2 ;;
        --nodes) NODES="$2"; shift 2 ;;
        -h|--help) sed -n '5,28p' "$0"; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
PASS=0; FAIL=0; GATE=0; UNCHECKED=0

ok()   { printf '  %sok%s     %s\n' "$GRN" "$OFF" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %sFAIL%s   %s\n' "$RED" "$OFF" "$*"; FAIL=$((FAIL+1)); }
gate() { printf '  %sgate%s   %s\n' "$YLW" "$OFF" "$*"; GATE=$((GATE+1)); }
# A missing tool is not a finding about the thing the tool would have looked at.
#
# Two of these were reported as failures: a missing dig became "seeding could
# not be checked at all" counted as red, and a release check that had exited 2
# -- this project's word for "could not run" -- became "the published download
# is NOT this network". The download was fine, the binaries were fine, and the
# report said otherwise on both counts, every run, on the machine the founder
# uses. Red lines that are always there are red lines nobody reads.
unchecked() { printf '  %swarn%s   %s\n' "$YLW" "$OFF" "$*"; UNCHECKED=$((UNCHECKED+1)); }
sect() { printf '\n%s%s%s\n' "$BLD" "$*" "$OFF"; }

rsh() { timeout 40 ssh -o BatchMode=yes -o ConnectTimeout=12 "root@$HOST" "$@" 2>/dev/null; }

echo "=================================================================="
echo " WAM preflight"
echo "=================================================================="

# ---------------------------------------------------------------------------
sect "The launch gate -- these cannot pass before the key ceremony"

FOUNDER="$(awk '/^static const std::string WAM_FOUNDER_ADDRESS_MAINNET/{
    if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2)}' src/wam/chainparams.cpp)"
TREASURY="$(awk '/^static const std::string WAM_TREASURY_ADDRESS_MAINNET/{
    if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2)}' src/wam/chainparams.cpp)"

if [ "$FOUNDER" = "WNg2svm2qApxheBKndKGQ9sRwporvRgRpT" ]; then
    gate "mainnet founder address is still the burn placeholder"
    gate "mainnet genesis cannot be mined until that address exists"
else
    ok "mainnet founder address is set: $FOUNDER"
fi

# The treasury is a separate gate because it fails differently and later. A
# burn address here does not stop the chain or show up in any test: blocks are
# valid, the rule is satisfied, and 750,000 WAM of operating income is
# destroyed one block at a time for eighteen months before anyone notices the
# balance never moved.
if [ "$TREASURY" = "WNg2svm2qApxheBKndKGQ9sRwporvRgRpT" ]; then
    gate "mainnet treasury address is still the burn placeholder"
    gate "every 5% fee would be destroyed -- 750,000 WAM, silently, over 400,000 blocks"
elif [ "$TREASURY" = "$FOUNDER" ]; then
    gate "mainnet treasury and founder are the same address"
    gate "treasury spending would be indistinguishable from the founder selling"
else
    ok "mainnet treasury address is set and separate: $TREASURY"
fi

# ---------------------------------------------------------------------------
sect "Identity -- would anyone mistake this for Bitcoin?"

# The check that a service-status sweep cannot make. wamd being a symlink to
# bitcoind passes every "is it running" test ever written.
if [ -n "$HOST" ]; then
    REAL="$(rsh 'readlink -f /usr/local/bin/wamd 2>/dev/null')"
    case "$REAL" in
        */wamd) ok "the installed node really is wamd, not a symlink to bitcoind" ;;
        */bitcoind) bad "wamd is a symlink to bitcoind -- collides with a real Bitcoin
           install, and package_release.sh cannot find src/wamd" ;;
        '') bad "no wamd on $HOST" ;;
        *)  bad "wamd resolves to $REAL" ;;
    esac
fi

if [ -d build/wam-core/src ] || [ -d "$HOME/wam/build/wam-core/src" ]; then
    T="build/wam-core"; [ -d "$T/src" ] || T="$HOME/wam/build/wam-core"
    if "$PY" scripts/rename_binaries.py --tree "$T" --check >/dev/null 2>&1; then
        ok "the build tree builds wamd / wam-cli / wam-tx / wam-util / wam-wallet"
    else
        bad "the build tree still builds Bitcoin's binary names
           run: "$PY" scripts/rename_binaries.py --tree $T"
    fi
fi

if [ -n "$HOST" ]; then
    # An unstripped wamd is 267 MB of debug symbols against 14 MB stripped.
    # Nobody downloading a currency wants a quarter of a gigabyte of symbols,
    # and it is large enough to make copying the node to a second machine over
    # an ordinary connection time out halfway.
    SZ="$(rsh 'stat -c%s /usr/local/bin/wamd 2>/dev/null')"
    if [ -n "$SZ" ] && [ "$SZ" -gt 62914560 ]; then
        bad "the installed wamd is $((SZ / 1048576)) MB -- debug symbols were not
           stripped. make install-strip, not make install"
    elif [ -n "$SZ" ]; then
        ok "the installed wamd is $((SZ / 1048576)) MB, stripped"
    fi

    # Twelve of these shipped silently for weeks.
    DEPS="$(rsh "ldd /usr/local/bin/wamd 2>/dev/null | awk '/=>/{print \$1}' \
            | grep -vE 'linux-vdso|ld-linux|libc\.so|libm\.so|libgcc_s|libstdc|libpthread|libdl|librt|libresolv' \
            | grep -vE 'libevent|libsqlite3' | sort -u")"
    if [ -z "$DEPS" ]; then
        ok "no runtime dependency beyond libevent and libsqlite3"
    else
        bad "extra runtime dependencies a downloader must already have:
           $(printf '%s' "$DEPS" | tr '\n' ' ')"
    fi
fi

# ---------------------------------------------------------------------------
sect "A stranger's first five minutes"

if [ "$(git ls-files -s -- install.sh | awk '{print $1}')" = "100755" ]; then
    ok "./install.sh is executable for anyone who clones"
else
    bad "./install.sh is not executable -- the first line of the README fails"
fi

bash scripts/test/test_exec_bits.sh >/dev/null 2>&1 \
    && ok "every shebang file is executable in the index" \
    || bad "some scripts are not executable in the index"

# One call, and the status is read rather than reinterpreted. This used to try
# a `--offline` flag first and fall back with `||`. That flag never existed:
# check_dns_seeds.sh took it as an unknown target, matched no branch, queried
# no seed and exited 0 -- so the fallback was never reached and this printed a
# green line for a check that had not run. Both ends are fixed; the script now
# refuses an argument it does not know and fails outright if it checked
# nothing, and nothing here converts a non-zero status into a pass.
bash scripts/check_dns_seeds.sh >/dev/null 2>&1
case $? in
    0) ok "every DNS seed answers the prefixed query Core actually sends" ;;
    2) bad "check_dns_seeds.sh rejected its argument -- this call is wrong" ;;
    3) unchecked "dig is missing, so seeding was NOT checked -- this is not a
           pass:  sudo apt-get install -y dnsutils" ;;
    *) bad "a DNS seed does not answer x9.<name> -- new nodes find nobody,
           silently, with no error" ;;
esac

# ---------------------------------------------------------------------------
sect "Can a release actually be built?"

# Not "do old tarballs exist" -- they did, from four weeks and 28 commits ago.
if grep -q 'BUILD_BASE' scripts/package_release.sh 2>/dev/null; then
    ok "package_release.sh finds the build tree from the repository"
else
    bad "package_release.sh hardcodes a home directory and fails on any other machine"
fi

# What people download is the published release, not a tarball on the machine
# that happens to be running this. That distinction was invisible while both
# were built by hand; it stopped being invisible when CI took over publishing,
# and this check went on failing for a stale local file nobody would ever
# receive -- red every run, for a fact about nothing, which is how a report
# teaches people to skim past its red lines.
#
# check_release_matches.sh asks the question that has consequences: it
# downloads the published artifact and looks inside it for the constants this
# source declares.
bash scripts/check_release_matches.sh >/dev/null 2>&1
case $? in
    0) ok "the published download carries this source's chains and addresses" ;;
    2) unchecked "part of the published download was NOT examined -- run:
           bash scripts/check_release_matches.sh" ;;
    *) bad "the published download is NOT this network -- run:
           bash scripts/check_release_matches.sh --source" ;;
esac

# A local tarball is a build artifact, so it is reported and never graded.
if [ -d out/release ]; then
    NEWEST=$(find out/release -name '*.tar.gz' -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    if [ -n "$NEWEST" ]; then
        BEHIND=$(git log --since="@${NEWEST%.*}" --oneline 2>/dev/null | wc -l)
        [ "$BEHIND" -gt 0 ] && printf '  %sinfo%s   out/release holds a local build %s commits old; it is\n         nobody'"'"'s download\n' "$YLW" "$OFF" "$BEHIND"
    fi
fi

# ---------------------------------------------------------------------------
sect "Money"

"$PY" scripts/verify_supply.py >/dev/null 2>&1 \
    && ok "the 22,000,000 cap is enforced by the arithmetic" \
    || bad "the supply audit fails"

for t in pool/test/*.test.js; do
    [ -f "$t" ] || continue
    node "$t" >/dev/null 2>&1 \
        && ok "$(basename "$t") passes" \
        || bad "$(basename "$t") FAILS -- this is payout code"
done

# ---------------------------------------------------------------------------
if [ -n "$HOST" ]; then
    sect "The running network"

    # What is this machine for?
    #
    # A seed node runs wamd and nothing else -- no pool, no dashboard, no
    # nginx -- and reporting six failures for services it was never meant to
    # have is a false alarm. This script says elsewhere that an operator shown
    # false alarms stops reading the real ones, so it has to know the
    # difference. The role is read from what is installed, not configured
    # anywhere, so a machine cannot drift from its own description.
    ROLE="seed"
    [ -n "$(rsh 'ls /etc/systemd/system/wam-pool.service 2>/dev/null')" ] && ROLE="full"
    printf '  %s%s%s node\n\n' "$BLD" "$ROLE" "$OFF"

    SERVICES="wamd"
    [ "$ROLE" = "full" ] && SERVICES="wamd wam-pool wam-dashboard wam-telegram nginx redis-server"

    for u in $SERVICES; do
        [ "$(rsh "systemctl is-active $u")" = "active" ] \
            && ok "$u is running" || bad "$u is not running"
    done

    # Reachability from outside, not a firewall rule that claims it.
    check_open() {
        if timeout 8 bash -c "exec 3<>/dev/tcp/$HOST/$1" 2>/dev/null; then
            ok "port $1 reachable from the internet -- $2"
        else
            bad "port $1 NOT reachable -- $2"
        fi
    }

    check_open 19555 "peer-to-peer, how the network is found"
    [ "$ROLE" = "full" ] && check_open 3333 "stratum"

    for spec in "19554 RPC, this is the wallet" "6379 redis, every miner balance"; do
        set -- $spec
        P="$1"; shift
        if timeout 8 bash -c "exec 3<>/dev/tcp/$HOST/$P" 2>/dev/null; then
            bad "port $P IS REACHABLE from the internet -- $*"
        else
            ok "port $P closed to the internet -- $*"
        fi
    done

    SEEDS=$(rsh 'wam-cli -conf=/root/.wam/wam.conf -datadir=/root/.wam getconnectioncount')
    [ "${SEEDS:-0}" -ge 1 ] 2>/dev/null \
        && ok "the node has $SEEDS peer(s)" \
        || bad "the node has no peers"
fi

# ---------------------------------------------------------------------------
sect "Single points of failure"

# Two nodes that disagree are worse than one node: the chain forks the moment
# either mines. On 2026-08-19 exactly that happened -- one node still enforced
# the pre-separation treasury address and rejected every block the other made,
# for hours, while both reported active and both reported /WAM:0.1.0/. Nothing
# a node says about itself can find this, so it is checked between nodes or
# not at all. Not passing --nodes is reported, never assumed harmless.
if [ -n "$NODES" ]; then
    if bash scripts/check_nodes_agree.sh $NODES >/dev/null 2>&1; then
        ok "every deployed node runs the same binaries and the same chain"
    else
        bad "the deployed nodes DISAGREE -- run:
           bash scripts/check_nodes_agree.sh $NODES"
    fi
else
    gate "node agreement unchecked -- pass --nodes \"ip1 ip2\" to compare the
           deployed nodes against each other"
fi

if [ -n "$HOST" ]; then
    NSEEDS=$(dig +short x9.seed1.wamcoin.org A 2>/dev/null | sort -u | wc -l)
    if [ "$NSEEDS" -le 1 ]; then
        bad "only $NSEEDS seed address. If that machine stops, nobody new can
           join the network at all -- existing nodes survive on cached peers"
    else
        ok "$NSEEDS independent seed addresses"
    fi
fi

echo
echo "=================================================================="
printf ' %s%d passed%s   %s%d failed%s   %s%d NOT checked%s   %s%d gated on the key ceremony%s\n' \
    "$GRN" "$PASS" "$OFF" "$RED" "$FAIL" "$OFF" \
    "$YLW" "$UNCHECKED" "$OFF" "$YLW" "$GATE" "$OFF"
if [ "$UNCHECKED" -gt 0 ]; then
    echo
    echo ' The lines marked warn were not measured. They are not passes, and'
    echo ' launch day is not the moment to discover what they would have said.'
fi
echo "=================================================================="
[ "$FAIL" -eq 0 ] || exit 1
[ "$UNCHECKED" -eq 0 ] || exit 2
exit 0

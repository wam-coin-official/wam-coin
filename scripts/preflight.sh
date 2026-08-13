#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  preflight.sh -- is this actually ready to launch?
# ===========================================================================
#
#      bash scripts/preflight.sh            # local checks only
#      bash scripts/preflight.sh --host IP  # also check a running server
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

HOST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        -h|--help) sed -n '5,28p' "$0"; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
PASS=0; FAIL=0; GATE=0

ok()   { printf '  %sok%s     %s\n' "$GRN" "$OFF" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %sFAIL%s   %s\n' "$RED" "$OFF" "$*"; FAIL=$((FAIL+1)); }
gate() { printf '  %sgate%s   %s\n' "$YLW" "$OFF" "$*"; GATE=$((GATE+1)); }
sect() { printf '\n%s%s%s\n' "$BLD" "$*" "$OFF"; }

rsh() { timeout 40 ssh -o BatchMode=yes -o ConnectTimeout=12 "root@$HOST" "$@" 2>/dev/null; }

echo "=================================================================="
echo " WAM preflight"
echo "=================================================================="

# ---------------------------------------------------------------------------
sect "The launch gate -- these cannot pass before the key ceremony"

FOUNDER="$(awk '/^static const std::string WAM_FOUNDER_ADDRESS_MAINNET/{
    if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2)}' src/wam/chainparams.cpp)"
if [ "$FOUNDER" = "WNg2svm2qApxheBKndKGQ9sRwporvRgRpT" ]; then
    gate "mainnet founder address is still the burn placeholder"
    gate "mainnet genesis cannot be mined until that address exists"
else
    ok "mainnet founder address is set: $FOUNDER"
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
    if python3 scripts/rename_binaries.py --tree "$T" --check >/dev/null 2>&1; then
        ok "the build tree builds wamd / wam-cli / wam-tx / wam-util / wam-wallet"
    else
        bad "the build tree still builds Bitcoin's binary names
           run: python3 scripts/rename_binaries.py --tree $T"
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

if bash scripts/check_dns_seeds.sh --offline >/dev/null 2>&1 \
   || bash scripts/check_dns_seeds.sh >/dev/null 2>&1; then
    ok "every DNS seed answers the prefixed query Core actually sends"
else
    bad "a DNS seed does not answer x9.<name> -- new nodes find nobody,
           silently, with no error"
fi

# ---------------------------------------------------------------------------
sect "Can a release actually be built?"

# Not "do old tarballs exist" -- they did, from four weeks and 28 commits ago.
if grep -q 'BUILD_BASE' scripts/package_release.sh 2>/dev/null; then
    ok "package_release.sh finds the build tree from the repository"
else
    bad "package_release.sh hardcodes a home directory and fails on any other machine"
fi

if [ -d out/release ]; then
    NEWEST=$(find out/release -name '*.tar.gz' -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    if [ -n "$NEWEST" ]; then
        BEHIND=$(git log --since="@${NEWEST%.*}" --oneline 2>/dev/null | wc -l)
        if [ "$BEHIND" -eq 0 ]; then
            ok "the packaged release matches the current code"
        else
            bad "the packaged release is $BEHIND commits behind -- it predates
           the RPC port change, the share-difficulty fix and the boot fix"
        fi
    fi
fi

# ---------------------------------------------------------------------------
sect "Money"

python3 scripts/verify_supply.py >/dev/null 2>&1 \
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

    for u in wamd wam-pool wam-dashboard wam-telegram nginx redis-server; do
        [ "$(rsh "systemctl is-active $u")" = "active" ] \
            && ok "$u is running" || bad "$u is not running"
    done

    # Reachability from outside, not a firewall rule that claims it.
    for spec in "19555 peer-to-peer, how the network is found" \
                "3333 stratum"; do
        set -- $spec
        P="$1"; shift
        if timeout 8 bash -c "exec 3<>/dev/tcp/$HOST/$P" 2>/dev/null; then
            ok "port $P reachable from the internet -- $*"
        else
            bad "port $P NOT reachable -- $*"
        fi
    done

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
printf ' %s%d passed%s   %s%d failed%s   %s%d gated on the key ceremony%s\n' \
    "$GRN" "$PASS" "$OFF" "$RED" "$FAIL" "$OFF" "$YLW" "$GATE" "$OFF"
echo "=================================================================="
[ "$FAIL" -eq 0 ]

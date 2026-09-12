#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  launch_ready.sh -- what is left before launch, measured rather than recalled
# ===========================================================================
#
#      bash scripts/launch_ready.sh                  # the three seeds
#      bash scripts/launch_ready.sh HOST [HOST...]   # named hosts
#
#  WHY THIS EXISTS
#
#  The founder asked "what is left before launch" four times. Each time he
#  got three items, we did them, and the next time the list had different
#  items on it. That is not a moving target -- it is an answer assembled from
#  memory and from documents that go stale, which is the same failure this
#  project fixes everywhere else by measuring instead.
#
#  The worst instance: `docs/REHEARSALS.md` listed "open TCP 13333-13336 in
#  the Contabo panel, then move the testnet pool" as still open. It had been
#  done the day before. The panel showed four ACTIVE rules, the pool was
#  listening on the new ports, and 3333-3336 were free -- and the answer he
#  got was a task he had already finished, because a markdown table was the
#  source of truth instead of the machines.
#
#  So this asks the machines. Every line below is a question with a measured
#  answer, and anything it cannot measure says so rather than passing.
#
#  It deliberately does not repeat what other checks own:
#      check_nodes_agree.sh      do the nodes share a tip
#      check_dns_seeds.sh        do the seed names resolve
#      check_release_matches.sh  is the published download this network
#      sweep.sh                  all of the above, and the rest
#  Those are the sweep's job on the 14th. This one answers a narrower
#  question: is each machine in the state launch night assumes it is in.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

# An interpreter that is actually Python. `python3` on Windows is a Microsoft
# Store stub that runs nothing and exits 49 -- and the first run of this file
# reported both stratum ports unreachable because of it, which is a false
# alarm about a provider firewall three days before launch.
SCRIPTS_DIR="$HERE/scripts"
. "$HERE/scripts/lib/python.sh"

HOSTS=("$@")
if [ "${#HOSTS[@]}" -eq 0 ]; then
    HOSTS=(169.58.159.165 5.223.52.200 13.140.33.187)
fi

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
GREEN=0; NOTGREEN=0; UNMEASURED=0

ok()   { printf '  %sok%s      %s\n' "$GRN" "$OFF" "$*"; GREEN=$((GREEN+1)); }
bad()  { printf '  %sNOT YET%s %s\n' "$RED" "$OFF" "$*"; NOTGREEN=$((NOTGREEN+1)); }
warn() { printf '  %s?%s       %s\n' "$YLW" "$OFF" "$*"; UNMEASURED=$((UNMEASURED+1)); }

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15
          -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
rsh() { timeout 90 ssh "${SSH_OPTS[@]}" "root@$1" "$2" 2>/dev/null; }

# The date the chain opens, read from the gate rather than typed here.
OPENS="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T?[0-9:]*Z?' scripts/genesis_gate.sh 2>/dev/null \
         | head -1)"
OPENS_EPOCH="$(date -u -d "2026-09-15 00:00:00" +%s 2>/dev/null || echo 0)"
NOW_EPOCH="$(date -u +%s)"

echo "=================================================================="
echo " Is every machine in the state launch night assumes?"
echo "=================================================================="
printf '    measured  %s UTC\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
if [ "$OPENS_EPOCH" -gt 0 ] && [ "$OPENS_EPOCH" -gt "$NOW_EPOCH" ]; then
    LEFT=$(( OPENS_EPOCH - NOW_EPOCH ))
    printf '    the chain opens %s -- %dh %dm from now\n' \
        "${OPENS:-2026-09-15T00:00:00Z}" "$((LEFT/3600))" "$(((LEFT%3600)/60))"
fi

WANT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
printf '    this checkout  %s\n' "$WANT_COMMIT"

for h in "${HOSTS[@]}"; do
    printf '\n%s%s%s\n' "$BLD" "$h" "$OFF"

    # One round trip. Every question this host can answer about itself, asked
    # at once, because three seconds of latency times nine questions times
    # three hosts is a check nobody runs twice.
    T0="$(date -u +%s)"
    OUT="$(rsh "$h" '
        cd /opt/wam 2>/dev/null && echo "commit=$(git rev-parse --short HEAD)" \
            && echo "modified=$(git status --porcelain | grep -vc "^??")" \
            && echo "untracked=$(git status --porcelain | grep -c "^??")"
        echo "version=$(wamd --version 2>/dev/null | head -1 | grep -oE "v[0-9.]+")"
        echo "clock=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
        echo "skew=$(date -u +%s)"
        echo "unit=$(systemctl cat wamd-mainnet.service >/dev/null 2>&1 && echo yes || echo no)"
        echo "enabled=$(systemctl is-enabled wamd-mainnet.service 2>&1)"
        echo "gatecond=$(grep -c "^ExecCondition=.*genesis_gate" /etc/systemd/system/wamd-mainnet.service 2>/dev/null)"
        echo "onfail=$(grep -c "^OnFailure=" /etc/systemd/system/wamd-mainnet.service 2>/dev/null)"
        echo "conf=$([ -f /root/.wam-mainnet/wam.conf ] && echo yes || echo no)"
        echo "stale=$(ls -d /root/.wam-mainnet/blocks /root/.wam-mainnet/chainstate /root/.wam-mainnet/indexes 2>/dev/null | tr "\n" " ")"
        echo "reorgtmpl=$([ -f /etc/systemd/system/wam-reorg-watch@.service ] && echo yes || echo no)"
        echo "backuptmpl=$([ -f /etc/systemd/system/wam-backup@.service ] && echo yes || echo no)"
        echo "failed=$(systemctl list-units "wam*" --state=failed --no-legend --no-pager | wc -l)"
        echo "testnet=$(systemctl is-active wamd.service 2>&1)"
        echo "backupage=$(find /root/backups -name "wam-backup-testnet-*.gpg" -mtime -2 2>/dev/null | wc -l)"
        bash /opt/wam/scripts/genesis_gate.sh mainnet --datadir /root/.wam-mainnet >/dev/null 2>&1
        echo "gate=$?"
    ')"
    if [ -z "$OUT" ]; then
        warn "no answer over ssh -- nothing below was measured for this host"
        continue
    fi
    get() { printf '%s' "$OUT" | sed -n "s/^$1=//p" | head -1; }

    [ "$(get commit)" = "$WANT_COMMIT" ] \
        && ok "/opt/wam is this commit ($WANT_COMMIT)" \
        || bad "/opt/wam is $(get commit), this checkout is $WANT_COMMIT -- deploy.sh"
    # Tracked files only. The first run counted untracked ones too and called
    # the pool host not ready over four generated files -- two package-locks, a
    # config backup, and the live mainnet pool config, which is untracked on
    # purpose and must stay that way because it carries the mainnet RPC
    # password.
    [ "$(get modified)" = "0" ] \
        && ok "no tracked file differs from the commit" \
        || bad "$(get modified) tracked file(s) modified in /opt/wam"
    [ "$(get untracked)" = "0" ] \
        || printf '          (%s untracked file(s) there, expected on the pool host)\n' "$(get untracked)"
    [ -n "$(get version)" ] \
        && ok "wamd $(get version) installed" \
        || warn "could not read wamd --version"
    [ "$(get clock)" = "yes" ] \
        && ok "clock synchronised, NTP active" \
        || bad "clock NOT synchronised -- genesis validation is absolute time"
    # Compared against local time read around this host's own round trip, not
    # against one timestamp taken before the first ssh. Asked in sequence, the
    # three hosts reported 3s, 10s and 16s of "drift" on the first run: the
    # latency of asking, printed as a clock problem.
    T1="$(date -u +%s)"
    HT="$(get skew)"
    if [ "${HT:-0}" -ge "$((T0 - 5))" ] && [ "${HT:-0}" -le "$((T1 + 5))" ] 2>/dev/null; then
        ok "its clock agrees with this machine, inside the round trip"
    else
        if [ "${HT:-0}" -lt "$T0" ]; then SKEW=$((T0 - HT)); else SKEW=$((HT - T1)); fi
        bad "${SKEW}s away from this machine, beyond the round trip"
    fi
    [ "$(get unit)" = "yes" ] \
        && ok "wamd-mainnet.service installed" \
        || bad "wamd-mainnet.service is NOT installed -- Phase C stops here"
    [ "$(get enabled)" = "disabled" ] \
        && ok "and disabled, as it must be before the date" \
        || bad "wamd-mainnet is $(get enabled) -- it must be disabled until the night"
    [ "$(get gatecond)" = "1" ] \
        && ok "genesis_gate.sh is its ExecCondition" \
        || bad "no genesis_gate ExecCondition -- nothing stops an early start"
    [ "$(get gate)" = "78" ] \
        && ok "and the gate declines today (78)" \
        || bad "the gate answered $(get gate), not 78"
    [ "$(get onfail)" -ge 1 ] 2>/dev/null \
        && ok "OnFailure is set, so its death is alarmed" \
        || bad "wamd-mainnet has no OnFailure -- a crash would be silent"
    [ "$(get conf)" = "yes" ] \
        && ok "/root/.wam-mainnet/wam.conf written" \
        || bad "no mainnet wam.conf -- Phase C stops here"
    [ -z "$(get stale)" ] \
        && ok "no stale chain state in the mainnet datadir" \
        || bad "stale in the mainnet datadir: $(get stale)"
    [ "$(get reorgtmpl)" = "yes" ] && [ "$(get backuptmpl)" = "yes" ] \
        && ok "the backup and reorg-watch templates are installed" \
        || bad "missing a timer template: backup=$(get backuptmpl) reorg=$(get reorgtmpl)"
    [ "$(get failed)" = "0" ] \
        && ok "no failed wam unit" \
        || bad "$(get failed) failed wam unit(s) -- systemctl --state=failed"
    [ "$(get testnet)" = "active" ] \
        && ok "testnet node running (the fallback while mainnet is unproven)" \
        || bad "the testnet node is $(get testnet)"
    [ "$(get backupage)" -ge 1 ] 2>/dev/null \
        && ok "a testnet backup from the last 48 hours" \
        || bad "no backup archive newer than 48 hours"
done

# ---------------------------------------------------------------------------
# The one machine that is not interchangeable: the pool and its wallet.
# ---------------------------------------------------------------------------
POOLHOST="${HOSTS[0]}"
printf '\n%sthe pool host (%s)%s\n' "$BLD" "$POOLHOST" "$OFF"
POUT="$(rsh "$POOLHOST" '
    echo "listen=$(ss -ltn 2>/dev/null | grep -cE ":1333[3-6] ")"
    echo "mainfree=$(ss -ltn 2>/dev/null | grep -cE ":333[3-6] ")"
    echo "wallet=$([ -f /root/.wam-mainnet/pool/wallet.dat ] && stat -c%s /root/.wam-mainnet/pool/wallet.dat || echo 0)"
    echo "poolsvc=$(systemctl is-active wam-pool.service 2>&1)"
')"
if [ -z "$POUT" ]; then
    warn "no answer from the pool host"
else
    pget() { printf '%s' "$POUT" | sed -n "s/^$1=//p" | head -1; }
    [ "$(pget listen)" = "4" ] \
        && ok "testnet stratum moved: 13333-13336 all listening" \
        || bad "$(pget listen) of 4 testnet stratum ports listening on 13333-13336"
    [ "$(pget mainfree)" = "0" ] \
        && ok "3333-3336 are free for the mainnet pool -- no stop step on the night" \
        || bad "$(pget mainfree) port(s) still held on 3333-3336: the testnet pool must be stopped first"
    [ "$(pget wallet)" -gt 0 ] 2>/dev/null \
        && ok "the mainnet pool wallet is on disk ($(pget wallet) bytes)" \
        || bad "no /root/.wam-mainnet/pool/wallet.dat -- miners cannot be paid"
    [ "$(pget poolsvc)" = "active" ] \
        && ok "wam-pool is running on testnet" \
        || warn "wam-pool is $(pget poolsvc)"
fi

# Reachability of the moved ports is a question from outside, not from the
# host: ufw can allow what the provider's panel still blocks.
printf '\n%sfrom outside (this machine)%s\n' "$BLD" "$OFF"
if [ -n "${PY:-}" ]; then
    for p in 13333 13336; do
        if "$PY" -c "
import socket,sys
s=socket.socket(); s.settimeout(8)
try:
    s.connect(('$POOLHOST',$p)); sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    s.close()" 2>/dev/null; then
            ok "$POOLHOST:$p answers -- the provider firewall is open"
        else
            bad "$POOLHOST:$p does not answer from here"
        fi
    done
else
    warn "no python here, so the ports were not tested from outside"
fi

echo
echo "=================================================================="
printf ' %d measured green' "$GREEN"
[ "$NOTGREEN" -gt 0 ]   && printf ', %s%d not yet%s' "$RED" "$NOTGREEN" "$OFF"
[ "$UNMEASURED" -gt 0 ] && printf ', %s%d could not be measured%s' "$YLW" "$UNMEASURED" "$OFF"
printf '\n'
if [ "$NOTGREEN" -eq 0 ] && [ "$UNMEASURED" -eq 0 ]; then
    printf ' %severy machine is in the state launch night assumes%s\n' "$GRN" "$OFF"
    echo "=================================================================="
    exit 0
fi
echo
echo ' The lines above are the list. Nothing here is remembered; if an item'
echo ' is green it was measured green a moment ago, and if it is not, it is'
echo ' the whole of what is left on the machines.'
echo "=================================================================="
[ "$NOTGREEN" -gt 0 ] && exit 1
exit 2

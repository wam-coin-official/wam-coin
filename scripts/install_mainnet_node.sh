#!/bin/bash
# ===========================================================================
#  install_mainnet_node.sh -- put the mainnet node unit on a host
# ===========================================================================
#
#      sudo bash scripts/install_mainnet_node.sh
#
#  Installs and does NOT enable. The gate in wamd-mainnet.service would
#  refuse an early start anyway, but a unit that is not enabled cannot be
#  started by a reboot either, and two locks are right for the one service
#  whose early start cannot be undone.
#
#  WHY THE MEMORY CEILING IS COMPUTED HERE
#
#  The unit ships MemoryMax=2G, which is correct on the 12 GB host and
#  meaningless on the 1.9 GB one -- a ceiling above the memory that exists is
#  not a ceiling, and when that host runs out, the kernel's OOM killer
#  chooses the victim rather than systemd. It scores by size, and on launch
#  night the largest process on that machine is the node.
#
#  So the ceiling is derived from the machine at install time, and left alone
#  where the shipped value already fits.
# ===========================================================================

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT=wamd-mainnet.service
DATADIR=/root/.wam-mainnet

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; OFF=$'\033[0m'
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '  %swarn%s  %s\n' "$YLW" "$OFF" "$*"; }
fail() { printf '  %sfail%s  %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail "run this with sudo"
[ -f "$REPO/deploy/systemd/$UNIT" ] || fail "no $UNIT in $REPO/deploy/systemd"

chmod 755 "$REPO/scripts/genesis_gate.sh"
install -m 644 "$REPO/deploy/systemd/$UNIT" "/etc/systemd/system/$UNIT"
ok "installed $UNIT"

# The node needs credentials that survive its own restart. Cookie auth does
# not: the cookie is rewritten at every start, so ElectrumX, the pool and the
# explorer would each work once. This has to be right before the node ever
# runs, because a mainnet node cannot be restarted before 15 September to
# pick up a change.
if [ -f "$DATADIR/wam.conf" ] && ! grep -q '^rpcuser=' "$DATADIR/wam.conf"; then
    warn "$DATADIR/wam.conf has no rpcuser, so the node would authenticate by
        cookie and every service reading it would break at the node's first
        restart. Add a fixed rpcuser/rpcpassword pair before launch."
fi

TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
SHIPPED_MB=2048
DROPIN=/etc/systemd/system/$UNIT.d
if [ "${TOTAL_MB:-0}" -gt 0 ] && [ "$TOTAL_MB" -lt $((SHIPPED_MB * 4 / 3)) ]; then
    # Half the machine: the node measured 569-596 MB on both hosts carrying a
    # 3,400-block chain, so half of even the small host is well above what it
    # uses, while still leaving the kernel and everything else a half.
    LIMIT=$((TOTAL_MB / 2))
    install -d -m 755 "$DROPIN"
    cat > "$DROPIN/20-memory.conf" <<EOF
[Service]
# Sized from this machine by scripts/install_mainnet_node.sh: ${TOTAL_MB}M
# total, so the shipped ${SHIPPED_MB}M would never bind and the OOM killer
# would pick the victim instead.
MemoryMax=${LIMIT}M
EOF
    ok "memory ceiling ${LIMIT}M of ${TOTAL_MB}M on this host"
else
    rm -f "$DROPIN/20-memory.conf" 2>/dev/null || true
    ok "shipped ceiling ${SHIPPED_MB}M fits this ${TOTAL_MB}M host"
fi

systemctl daemon-reload

# Prove the gate rather than trusting it, and ask the gate itself whether the
# network is open rather than repeating the date here -- two copies of a
# constant are one copy too many, and this one decides whether a chain can
# start.
# set -e would kill this script on the gate's own refusal, before the case
# below could read it -- which is how the first version of this file skipped
# its entire verification section and still printed nothing but ok lines.
GATE=0
"$REPO/scripts/genesis_gate.sh" mainnet >/dev/null 2>&1 || GATE=$?
case $GATE in
  0)  ok "mainnet is open; the gate no longer refuses anything" ;;
  78)
    # An ExecCondition that declines returns success to systemctl start and
    # leaves the unit not running, so the exit code of `systemctl start`
    # proves nothing. What has to be true is that the node is not running and
    # that it was refused once rather than repeatedly -- and one RestartSec
    # has to pass before those can be told apart.
    MARK="$(date -u '+%Y-%m-%d %H:%M:%S')"
    systemctl start "$UNIT" >/dev/null 2>&1 || true
    sleep 25

    STATE="$(systemctl is-active "$UNIT" 2>/dev/null)"
    TRIES="$(journalctl -u "$UNIT" --since "$MARK" --no-pager -o cat 2>/dev/null \
             | grep -c 'refusing to start' || true)"

    if [ "$STATE" = "active" ] || [ "$STATE" = "activating" ]; then
        systemctl stop "$UNIT" || true
        systemctl reset-failed "$UNIT" 2>/dev/null || true
        fail "$UNIT is '$STATE' before its genesis date, after refusing
        ${TRIES:-?} times. Restart= is re-entering the refusal: the gate must
        be an ExecCondition, where an exit of 1..254 skips the start without
        marking the unit failed. As an ExecStartPre, or inside ExecStart, it
        loops."
    fi
    if [ "${TRIES:-0}" -gt 1 ]; then
        fail "the gate refused $TRIES times in 25 seconds. It is being
        retried, which is the loop this exists to prevent."
    fi
    ok "refused once and stopped -- unit is $STATE, $TRIES refusal in the journal"
    systemctl reset-failed "$UNIT" 2>/dev/null || true
    ;;
  *)  warn "genesis_gate.sh returned an unexpected status; check it by hand" ;;
esac

printf '\n  Not enabled, on purpose. On 15 September:\n\n'
printf '      sudo systemctl enable --now %s\n\n' "$UNIT"

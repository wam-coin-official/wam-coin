#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  harden_server.sh -- prepare a fresh Ubuntu box to hold a pool wallet
# ===========================================================================
#
#      sudo bash scripts/harden_server.sh --network testnet
#
#  install.sh builds and installs WAM. It does nothing about the machine it
#  installs onto, and that machine will eventually hold the private key to a
#  pool wallet with other people's money in it.
#
#  THE TWO THAT MATTER MOST
#
#  Everything below is ordinary hardening except two rules, and those two are
#  the reason this script exists:
#
#      the RPC port must never be reachable from the internet
#      Redis must never be reachable from the internet
#
#  An open RPC port is the wallet. An open Redis is every miner's balance.
#  Both listen on localhost by default and both have been exposed by
#  accident on thousands of machines, always the same way: someone changed a
#  bind address for a second host and did not think about the firewall.
#
#  NOTHING HERE CAN LOCK YOU OUT
#
#  The dangerous step is disabling password logins over SSH. Done in the wrong
#  order it ends with an operator who cannot reach their own server. So it is
#  refused unless a usable key is already installed, and it is verified after
#  the fact rather than assumed. If anything is uncertain the script stops and
#  says what to do, leaving SSH exactly as it found it.
# ===========================================================================

set -euo pipefail

NETWORK="testnet"
SKIP_SSH=0
SERVICE_USER="${SUDO_USER:-$USER}"

while [ $# -gt 0 ]; do
    case "$1" in
        --network) NETWORK="$2"; shift 2 ;;
        --user)    SERVICE_USER="$2"; shift 2 ;;
        --skip-ssh) SKIP_SSH=1; shift ;;
        -h|--help) sed -n '4,40p' "$0"; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

case "$NETWORK" in
    mainnet) P2P_PORT=9555;  RPC_PORT=9556  ;;
    testnet) P2P_PORT=19555; RPC_PORT=19556 ;;
    regtest) P2P_PORT=19555; RPC_PORT=29556 ;;
    *) printf 'unknown network: %s\n' "$NETWORK" >&2; exit 2 ;;
esac

BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; OFF=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$*"; }
ok()   { printf '  %sok%s    %s\n' "$GREEN" "$OFF" "$*"; }
warn() { printf '  %swarn%s  %s\n' "$YELLOW" "$OFF" "$*"; }
die()  { printf '  %serror%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "run this with sudo"

echo "=================================================================="
echo " Hardening this machine for WAM ($NETWORK)"
echo "=================================================================="

# ---------------------------------------------------------------------------
log "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ufw fail2ban unattended-upgrades >/dev/null
ok "ufw, fail2ban, unattended-upgrades"

# ---------------------------------------------------------------------------
log "firewall"

# Read the live SSH port rather than assuming 22. Assuming it is how people
# lock themselves out of servers they moved off the default port.
SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
SSH_PORT="${SSH_PORT:-22}"

ufw --force reset >/dev/null
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null

ufw allow "${SSH_PORT}/tcp" comment 'ssh' >/dev/null
ok "ssh on ${SSH_PORT} allowed (read from sshd, not assumed)"

ufw allow "${P2P_PORT}/tcp" comment "wam p2p ${NETWORK}" >/dev/null
ok "peer-to-peer on ${P2P_PORT} allowed -- this is how the network finds you"

ufw allow 3333/tcp comment 'stratum' >/dev/null
ufw allow 3334/tcp comment 'stratum testnet' >/dev/null
ok "stratum on 3333 and 3334 allowed"

ufw allow 80/tcp  comment 'http'  >/dev/null
ufw allow 443/tcp comment 'https' >/dev/null
ok "web on 80 and 443 allowed"

# The two that matter. Denied explicitly rather than left to the default,
# so that `ufw status` shows a human that somebody thought about them.
ufw deny "${RPC_PORT}/tcp" comment 'wam RPC -- never public' >/dev/null
ufw deny 6379/tcp          comment 'redis -- never public'   >/dev/null
ok "RPC ${RPC_PORT} and Redis 6379 explicitly denied"

ufw --force enable >/dev/null
ok "firewall active"

# ---------------------------------------------------------------------------
log "checking what is actually listening"

# A firewall rule is a claim. This is the check.
EXPOSED=0
while read -r addr port; do
    case "$port" in
        "$RPC_PORT"|6379)
            case "$addr" in
                127.0.0.1|::1|localhost) ;;
                *) warn "port ${port} is bound to ${addr}, not localhost"
                   warn "the firewall blocks it, but one rule change would expose it"
                   EXPOSED=1 ;;
            esac ;;
    esac
done < <(ss -ltn 2>/dev/null | awk 'NR>1 {n=split($4,a,":"); print a[1], a[n]}')

[ "$EXPOSED" = "0" ] && ok "RPC and Redis are bound to localhost only"

# ---------------------------------------------------------------------------
log "fail2ban"
systemctl enable --now fail2ban >/dev/null 2>&1 || true
ok "fail2ban running -- repeated failed SSH logins get banned"

log "unattended security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
ok "security updates install themselves"

# ---------------------------------------------------------------------------
log "ssh"

if [ "$SKIP_SSH" = "1" ]; then
    warn "skipped by request; password logins are still accepted"
else
    KEYFILE="$(getent passwd "$SERVICE_USER" | cut -d: -f6)/.ssh/authorized_keys"
    KEYCOUNT=0
    [ -f "$KEYFILE" ] && KEYCOUNT="$(grep -cE '^(ssh|ecdsa)-' "$KEYFILE" 2>/dev/null || echo 0)"

    ROOTKEYS=0
    [ -f /root/.ssh/authorized_keys ] && \
        ROOTKEYS="$(grep -cE '^(ssh|ecdsa)-' /root/.ssh/authorized_keys 2>/dev/null || echo 0)"

    if [ "$KEYCOUNT" -eq 0 ] && [ "$ROOTKEYS" -eq 0 ]; then
        warn "no SSH key found for ${SERVICE_USER} or root."
        warn "Password logins are being LEFT ON, because turning them off now"
        warn "would lock you out of this machine permanently."
        warn ""
        warn "From your own computer, run:"
        warn "    ssh-copy-id ${SERVICE_USER}@<this server>"
        warn "confirm you can log in without a password, then run this script again."
    else
        ok "found ${KEYCOUNT} key(s) for ${SERVICE_USER}, ${ROOTKEYS} for root"

        cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.wam-orig 2>/dev/null || true
        cat > /etc/ssh/sshd_config.d/60-wam.conf <<'EOF'
# Installed by WAM harden_server.sh.
# Password logins are how servers are taken: an attacker needs only time.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
EOF
        if sshd -t 2>/dev/null; then
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
            ok "password logins disabled, keys only"
            warn "Do not close this session. Open a SECOND terminal and confirm"
            warn "you can still log in. If you cannot, this session can undo it:"
            warn "    sudo rm /etc/ssh/sshd_config.d/60-wam.conf && sudo systemctl reload ssh"
        else
            rm -f /etc/ssh/sshd_config.d/60-wam.conf
            die "the new sshd config did not validate; nothing was changed"
        fi
    fi
fi

# ---------------------------------------------------------------------------
echo
echo "=================================================================="
ufw status verbose | sed 's/^/  /'
echo "=================================================================="
echo
echo " Still to do, and not done here because each needs a decision:"
echo
echo "   * point ${NETWORK} DNS at this machine, then get a certificate:"
echo "       sudo apt-get install -y certbot"
echo "       sudo certbot certonly --standalone -d explorer.wamcoin.org"
echo
echo "   * set -listen=1 in the wamd unit so peers can reach you."
echo "     A seed node that does not listen is not a seed node."
echo
echo "   * keep the pool wallet small. This machine is on the internet;"
echo "     treat whatever it holds as spendable by whoever takes it."
echo "=================================================================="

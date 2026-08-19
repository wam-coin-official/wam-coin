#!/bin/bash
# ===========================================================================
#  install.sh -- an ElectrumX server for WAM
# ===========================================================================
#
#      sudo bash integration/electrumx/install.sh [--network testnet|mainnet]
#
#  Komodo Wallet cannot list a UTXO coin without ElectrumX servers carrying
#  valid SSL; their repository has an electrums/ directory and an entry there is
#  required, not optional. Separately, this is what lets a light wallet read a
#  balance without downloading the chain.
#
#  WHICH ELECTRUMX, AND WHY
#
#  Three exist and only one fits:
#
#    kyuupichan/electrumx  the original. Now specialised to Bitcoin SV: its
#                          only two coin classes are BSV and BSV testnet. BSV
#                          has no SegWit and a different transaction format.
#    romanz/electrs        maintained and fast, but written in Rust with the
#                          networks compiled in. A fork, not a config.
#    spesmilo/electrumx    maintained, 165 coin classes, SegWit. This one.
#
#  spesmilo's 2.0 targets Bitcoin Core 31 and wants a txospenderindex that Core
#  31 added for Electrum protocol 1.7. WAM is Core v28.1 and has neither, so the
#  WAM coin class lowers both. That was tested, not assumed -- see
#  wam_coins.py.
#
#  This server holds no keys. It reads the node and answers questions.
# ===========================================================================

set -euo pipefail

NETWORK="testnet"
DOMAIN="electrum.wamcoin.org"
EX_DIR=/opt/electrumx
EX_USER=electrumx
DB_DIR=/var/lib/electrumx-wam
ENV_FILE=/etc/wam/electrumx.env
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --network) NETWORK="${2:?--network needs a value}"; shift ;;
        --domain)  DOMAIN="${2:?--domain needs a value}"; shift ;;
        -h|--help) sed -n '3,30p' "$0"; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

case "$NETWORK" in
    mainnet) RPC_PORT=9554  ;;
    testnet) RPC_PORT=19554 ;;
    *) echo "network must be mainnet or testnet" >&2; exit 2 ;;
esac

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; OFF=$'\033[0m'
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '  %swarn%s  %s\n' "$YLW" "$OFF" "$*"; }
fail() { printf '  %sfail%s  %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
step() { printf '\n%s%s%s\n' "$CYN" "$*" "$OFF"; }

[ "$(id -u)" = 0 ] || fail "run this with sudo"

# ---------------------------------------------------------------------------
step "1. dependencies"

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    git python3-venv python3-dev build-essential libleveldb-dev certbot >/dev/null 2>&1
ok "build tools, leveldb and certbot"

# ---------------------------------------------------------------------------
step "2. the user this runs as"

id -u "$EX_USER" >/dev/null 2>&1 || \
    useradd --system --no-create-home --shell /usr/sbin/nologin "$EX_USER"
ok "$EX_USER (system account, no shell, no home)"

install -d -o "$EX_USER" -g "$EX_USER" -m 0750 "$DB_DIR"
ok "$DB_DIR"

# ---------------------------------------------------------------------------
step "3. ElectrumX"

if [ ! -d "$EX_DIR/.git" ]; then
    git clone -q --depth 1 https://github.com/spesmilo/electrumx.git "$EX_DIR"
fi
ok "$(cd "$EX_DIR" && git log --oneline -1)"

[ -d "$EX_DIR/venv" ] || python3 -m venv "$EX_DIR/venv"
"$EX_DIR/venv/bin/pip" install -q --upgrade pip setuptools wheel

# spesmilo's fork uses pyproject.toml and resolves its own dependencies, so the
# normal isolated build works. The older kyuupichan layout did not: its
# setup.py imported the package to read its version, and the package imported
# aiorpcx, which an isolated build environment cannot resolve. Both paths are
# kept because the failure is silent-looking -- pip reports a build error, not
# a missing dependency, and the first reading sends you after the wrong thing.
if ! "$EX_DIR/venv/bin/pip" install -q "$EX_DIR" 2>/dev/null; then
    warn "isolated build failed; retrying without isolation"
    [ -f "$EX_DIR/requirements.txt" ] && \
        "$EX_DIR/venv/bin/pip" install -q -r "$EX_DIR/requirements.txt"
    "$EX_DIR/venv/bin/pip" install -q --no-build-isolation "$EX_DIR"
fi

# plyvel is the leveldb binding and is an extra rather than a dependency, so it
# is never pulled in by either path above.
"$EX_DIR/venv/bin/pip" install -q plyvel
ok "installed"

python3 "$REPO/integration/electrumx/wam_coins.py" \
    "$EX_DIR/src/electrumx/lib/coins.py" | sed 's/^/  /'

chmod -R a+rX "$EX_DIR"

# ---------------------------------------------------------------------------
step "4. the certificate"

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    MY_IP="$(curl -s -m 15 https://api.ipify.org || true)"
    DNS_IP="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)"
    [ -n "$DNS_IP" ] || fail "$DOMAIN does not resolve; add an A record first"
    [ "$MY_IP" = "$DNS_IP" ] || fail "$DOMAIN points at $DNS_IP, not this host ($MY_IP)"

    if ss -lnt | grep -q ':80 '; then
        certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos \
            -m wam.coin.official@proton.me
    else
        certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos \
            -m wam.coin.official@proton.me
    fi
fi
[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] || fail "no certificate"
ok "certificate for $DOMAIN, renewing automatically"

# ElectrumX reads the certificate as its own unprivileged user, so it needs to
# traverse letsencrypt's directories. Group-readable rather than world.
groupadd -f ssl-cert
usermod -aG ssl-cert "$EX_USER"
chgrp -R ssl-cert /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
chmod -R g+rX /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
ok "certificate readable by $EX_USER, and by nobody else"

# ---------------------------------------------------------------------------
step "5. configuration"

RPCU="$(grep -m1 '^rpcuser=' /root/.wam/wam.conf | cut -d= -f2-)"
RPCP="$(grep -m1 '^rpcpassword=' /root/.wam/wam.conf | cut -d= -f2-)"
[ -n "$RPCU" ] && [ -n "$RPCP" ] || fail "could not read RPC credentials from /root/.wam/wam.conf"

mkdir -p /etc/wam
# Written 0600 first, so the credentials are never briefly world-readable
# while the file is being assembled.
umask 077
cat > "$ENV_FILE" <<EOF
COIN=WAMCoin
NET=$NETWORK
DB_ENGINE=leveldb
DB_DIRECTORY=$DB_DIR
DAEMON_URL=http://$RPCU:$RPCP@127.0.0.1:$RPC_PORT/
SERVICES=tcp://:50001,ssl://:50002,wss://:50004,rpc://127.0.0.1:8000
REPORT_SERVICES=tcp://$DOMAIN:50001,ssl://$DOMAIN:50002,wss://$DOMAIN:50004
SSL_CERTFILE=/etc/letsencrypt/live/$DOMAIN/fullchain.pem
SSL_KEYFILE=/etc/letsencrypt/live/$DOMAIN/privkey.pem
PEER_DISCOVERY=self
PYTHONPATH=$EX_DIR/src
EOF
chown root:"$EX_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"
ok "$ENV_FILE (0640, root:$EX_USER)"

# ---------------------------------------------------------------------------
step "6. the service"

install -m 644 "$REPO/deploy/systemd/wam-electrumx.service" \
    /etc/systemd/system/wam-electrumx.service
systemctl daemon-reload
ok "installed wam-electrumx.service"

printf '\n  Start it with:\n\n      sudo systemctl enable --now wam-electrumx\n\n'
printf '  Then open 50001, 50002 and 50004 -- and open them TWICE. ufw is only\n'
printf '  half of it: Contabo drops inbound TCP to any port that is not on an\n'
printf '  allow-list in their control panel, and a dropped packet is silent, so\n'
printf '  the server looks perfect from the inside while nothing can reach it.\n\n'
printf '      sudo ufw allow 50001/tcp && sudo ufw allow 50002/tcp && sudo ufw allow 50004/tcp\n\n'
printf '  Then prove it from a DIFFERENT machine, never from this one:\n\n'
printf '      bash scripts/check_reachable.sh --host <this ip> --from <other ip> \\\n'
printf '          50001 50002 50004\n\n'
printf '  50004 carries the Electrum protocol over WebSocket, which is how the\n'
printf '  web build of Komodo Wallet connects. Desktop and mobile use 50002.\n\n'

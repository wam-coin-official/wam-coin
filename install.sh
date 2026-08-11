#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  install.sh -- one-command WAM Coin deployment for Ubuntu 22.04 / 24.04 LTS
# ===========================================================================
#
#      ./install.sh                  full install: node + pool
#      ./install.sh --node-only      just wamd / wam-cli
#      ./install.sh --pool-only      just the stratum pool
#      ./install.sh --build-only     compile, do not start anything
#      ./install.sh --network testnet
#      ./install.sh --skip-deps      do not touch apt
#
#  What it does, in order:
#      1. install build dependencies
#      2. fetch and patch Bitcoin Core, build librandomx
#      3. compile wamd / wam-cli
#      4. generate wam.conf with a random RPC password
#      5. build the pool's RandomX addon and install its node modules
#      6. install systemd units and start the node
#
#  What it deliberately does NOT do:
#      * generate the founder key (that must happen on an offline machine)
#      * mine the genesis block for you (you must own that decision)
#      * open any firewall port (yours to decide)
# ===========================================================================

set -euo pipefail

# --------------------------------------------------------------------------

NETWORK="mainnet"
DO_NODE=1
DO_POOL=1
DO_START=1
SKIP_DEPS=0
JOBS="$(nproc 2>/dev/null || echo 4)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$REPO_ROOT/build"
CORE_DIR="$BUILD_DIR/wam-core"
RANDOMX_DIR="$BUILD_DIR/randomx"
PREFIX="${PREFIX:-/usr/local}"
DATA_DIR="${WAM_DATA_DIR:-$HOME/.wam}"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; CYN=$'\033[0;36m'; OFF=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$CYN" "$OFF" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '%s  !!%s %s\n' "$YLW" "$OFF" "$*"; }
die()  { printf '%sERROR:%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

step() {
    printf '\n%s%s%s\n' "$CYN" "$(printf '=%.0s' {1..74})" "$OFF"
    printf '%s %s%s\n' "$CYN" "$*" "$OFF"
    printf '%s%s%s\n' "$CYN" "$(printf '=%.0s' {1..74})" "$OFF"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --node-only)  DO_POOL=0 ;;
        --pool-only)  DO_NODE=0 ;;
        --build-only) DO_START=0 ;;
        --skip-deps)  SKIP_DEPS=1 ;;
        --network)    NETWORK="${2:?--network needs a value}"; shift ;;
        --jobs)       JOBS="${2:?--jobs needs a value}"; shift ;;
        -h|--help)    sed -n '5,30p' "$0"; exit 0 ;;
        *) die "unknown option '$1' (try --help)" ;;
    esac
    shift
done

case "$NETWORK" in
    mainnet|testnet|regtest) ;;
    *) die "--network must be mainnet, testnet or regtest" ;;
esac

[ "$(id -u)" -eq 0 ] && warn "running as root; the node will be installed for the root user"

step "WAM Coin installer -- network: $NETWORK"

# ===========================================================================
step "1/6  Build dependencies"
# ===========================================================================

if [ "$SKIP_DEPS" = "1" ]; then
    warn "skipping apt (--skip-deps)"
else
    if ! command -v apt-get >/dev/null; then
        die "this installer targets Ubuntu 22.04 or 24.04. On another distribution, install the
     equivalents of the package list in docs/BUILD.md and re-run with --skip-deps."
    fi

    log "apt-get update"
    sudo apt-get update -qq

    log "installing toolchain and libraries"
    sudo apt-get install -y -qq \
        build-essential libtool autotools-dev automake pkg-config bsdmainutils \
        cmake curl git ca-certificates python3 python3-pip \
        libevent-dev libboost-dev libssl-dev libsqlite3-dev \
        libzmq3-dev systemd

    if [ "$DO_POOL" = "1" ]; then
        if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 18 ]; then
            log "installing Node.js 20 LTS"
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null
            sudo apt-get install -y -qq nodejs
        fi
        log "installing redis-server"
        sudo apt-get install -y -qq redis-server
        sudo systemctl enable --now redis-server

        # Redis holds every miner's balance and, out of the box, answers
        # anybody who asks. Binding it to localhost is not a defence: every
        # process and every user on this host is local, and the commonest
        # Redis incident in the wild is an operator widening `bind` later and
        # forgetting that nothing else was ever in the way.
        #
        # Generated here rather than left to the operator, because a step that
        # can be skipped is a step that will be.
        if ! sudo grep -qE '^requirepass +\S' /etc/redis/redis.conf 2>/dev/null; then
            log "securing redis with a generated password"
            WAM_REDIS_PASS="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40)"

            # Delete before appending: appending alone leaves one dead line per
            # run, and the file quietly grows every time this script is used.
            sudo sed -i '/^requirepass /d' /etc/redis/redis.conf
            printf 'requirepass %s\n' "$WAM_REDIS_PASS" | sudo tee -a /etc/redis/redis.conf >/dev/null
            sudo chmod 640 /etc/redis/redis.conf
            sudo systemctl restart redis-server
            sleep 2

            if redis-cli ping 2>&1 | grep -q NOAUTH; then
                ok "redis now refuses unauthenticated clients"
            else
                die "redis still answers without a password; refusing to continue"
            fi
            export WAM_REDIS_PASS
        else
            log "redis already has a password; leaving it alone"
        fi
    fi
    ok "dependencies installed"
fi

command -v python3 >/dev/null || die "python3 is required"

# ===========================================================================
step "2/6  Verifying the monetary policy before building anything"
# ===========================================================================

# If the arithmetic does not hold there is no point compiling: the whole
# proposition of this chain is the 22,000,000 cap.
python3 "$REPO_ROOT/scripts/verify_supply.py" || die "the monetary policy audit failed"
python3 "$REPO_ROOT/scripts/gen_founder_key.py" --selftest >/dev/null \
    || die "the address-prefix self-test failed"
python3 "$REPO_ROOT/genesis/test_serialization.py" >/dev/null \
    || die "the genesis serialization test failed"
ok "supply audit, prefix table and genesis serialization all verified"

# ===========================================================================
if [ "$DO_NODE" = "1" ]; then
step "3/6  Fetching upstream and building the node"
# ===========================================================================

bash "$REPO_ROOT/scripts/fetch-upstream.sh"

cd "$CORE_DIR"

# The generated chainparams carries every network's founder address at once.
# Grepping the whole file asks "is any address a placeholder", when the only
# question that matters is "is the address THIS build will actually use a
# placeholder". Mainnet is legitimately still the burn address until the key
# ceremony is held, so the broad grep blocked every testnet and signet build
# for a reason that has nothing to do with them.
BURN_MAINNET="WNg2svm2qApxheBKndKGQ9sRwporvRgRpT"
BURN_TESTNET="T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"

case "$NETWORK" in
    mainnet)        FOUNDER_SYM="WAM_FOUNDER_ADDRESS_MAINNET" ;;
    testnet|signet) FOUNDER_SYM="WAM_FOUNDER_ADDRESS_TESTNET" ;;
    *)              FOUNDER_SYM="" ;;   # regtest pays nobody
esac

FOUNDER_ADDR=""
if [ -n "$FOUNDER_SYM" ]; then
    # Anchored on the declaration, not on the symbol name. chainparams.cpp
    # also mentions WAM_FOUNDER_ADDRESS_MAINNET inside a quoted C++ error
    # string, and a looser pattern happily returns that sentence as the
    # treasury address.
    #
    # Reads to END rather than stopping at the first hit. `| head -1` closes
    # the pipe early, the producer dies of SIGPIPE, pipefail makes the
    # pipeline 141, and set -e aborts the assignment without printing
    # anything -- the same failure that made harden_server.sh report a
    # success it had not performed.
    FOUNDER_ADDR="$(awk -v s="$FOUNDER_SYM" '
        $0 ~ ("^static const std::string[[:space:]]+" s "[[:space:]]*=") {
            if (match($0, /"[^"]*"/)) a = substr($0, RSTART + 1, RLENGTH - 2)
        }
        END { print a }' src/kernel/chainparams.cpp)"
    [ -n "$FOUNDER_ADDR" ] || die "could not read ${FOUNDER_SYM} from the generated
     chainparams. Refusing to build a chain whose treasury address cannot be read."
    log "founder address for ${NETWORK}: ${FOUNDER_ADDR}"
fi

# Building anything other than mainnet while mainnet is unfinished is normal
# and expected. Saying so is not: a binary that carries a burn address for a
# network it can still be pointed at is worth one loud sentence.
if [ "$NETWORK" != "mainnet" ] && grep -q "$BURN_MAINNET" src/kernel/chainparams.cpp; then
    warn "this binary still carries the burn placeholder as the MAINNET founder"
    warn "address. It is fine for ${NETWORK}. Never run it with -chain=main."
fi

if [ -n "$FOUNDER_SYM" ] \
   && { [ "$FOUNDER_ADDR" = "$BURN_MAINNET" ] || [ "$FOUNDER_ADDR" = "$BURN_TESTNET" ]; }; then
    printf '\n%s%s%s\n' "$YLW" "$(printf '=%.0s' {1..74})" "$OFF"
    warn "STOPPING: the founder address is still the burn placeholder."
    warn ""
    warn "  The 2,000,000 WAM premine and the 5% treasury fee both pay this address."
    warn "  Its hash160 is twenty zero bytes -- nobody holds the key, so building a"
    warn "  mainnet binary with it would destroy both, permanently and verifiably."
    warn ""
    warn "  On an OFFLINE machine:"
    warn "      python3 scripts/gen_founder_key.py --network $NETWORK"
    warn ""
    warn "  Then edit src/wam/chainparams.cpp, mine the genesis block:"
    warn "      python3 genesis/genesis_generator.py --network $NETWORK \\"
    warn "          --address <the W... address> --patch src/wam/chainparams.cpp"
    warn ""
    warn "  and run this installer again."
    warn ""
    warn "  To try things out first:  ./install.sh --network regtest"
    printf '%s%s%s\n\n' "$YLW" "$(printf '=%.0s' {1..74})" "$OFF"
    exit 1
fi

log "configuring (autotools)"
[ -f ./configure ] || ./autogen.sh >/dev/null

RANDOMX_CFLAGS="-I$RANDOMX_DIR/src"
RANDOMX_LIBS="$RANDOMX_DIR/build/librandomx.a"

./configure \
    --prefix="$PREFIX" \
    --without-gui \
    --disable-tests-fuzz-binary \
    --with-incompatible-bdb \
    CPPFLAGS="$RANDOMX_CFLAGS" \
    LIBS="$RANDOMX_LIBS -lpthread" \
    >/dev/null || die "configure failed -- see config.log in $CORE_DIR"

log "compiling with $JOBS jobs (this takes 10-40 minutes)"
make -j"$JOBS" >/dev/null || die "the build failed"

log "running the WAM consensus unit tests"
if [ -x ./src/test/test_bitcoin ]; then
    ./src/test/test_bitcoin --run_test=wam_monetary_tests,wam_devfee_tests \
        || die "the WAM consensus tests failed -- refusing to install this binary"
    ok "consensus tests pass"
fi

log "installing binaries to $PREFIX/bin"
sudo make install >/dev/null

# The upstream build produces bitcoind/bitcoin-cli names; expose them as WAM.
for pair in "bitcoind:wamd" "bitcoin-cli:wam-cli" "bitcoin-tx:wam-tx" "bitcoin-util:wam-util"; do
    src="${pair%%:*}"; dst="${pair##*:}"
    if [ -f "$PREFIX/bin/$src" ] && [ ! -e "$PREFIX/bin/$dst" ]; then
        sudo ln -sf "$PREFIX/bin/$src" "$PREFIX/bin/$dst"
    fi
done
ok "wamd and wam-cli installed"

# ---------------------------------------------------------------------------
step "4/6  Node configuration"
# ---------------------------------------------------------------------------

mkdir -p "$DATA_DIR"
CONF="$DATA_DIR/wam.conf"

if [ -f "$CONF" ]; then
    ok "$CONF already exists; leaving it alone"
    RPC_PASS="$(grep -m1 '^rpcpassword=' "$CONF" | cut -d= -f2- || true)"
else
    RPC_PASS="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)"

    case "$NETWORK" in
        mainnet) NET_LINE="" ;;
        testnet) NET_LINE="testnet=1" ;;
        regtest) NET_LINE="regtest=1" ;;
    esac

    cat > "$CONF" <<EOF
# WAM Coin node configuration
# generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)

$NET_LINE

server=1
daemon=0
txindex=1

rpcuser=wamrpc
rpcpassword=$RPC_PASS
rpcbind=127.0.0.1
rpcallowip=127.0.0.1

# The pool needs getblocktemplate, which requires an unlocked, indexed node.
# Do NOT expose this RPC port to the internet.

listen=1
maxconnections=125

# RandomX validation uses light mode (~256 MiB). Set randomxmining=1 only if
# this node will also mine, which needs roughly 2.1 GiB more.
randomxmining=0

dbcache=450
EOF
    chmod 600 "$CONF"
    ok "wrote $CONF with a random RPC password (mode 0600)"
fi

# ---------------------------------------------------------------------------
log "installing the systemd unit"

sudo tee /etc/systemd/system/wamd.service >/dev/null <<EOF
[Unit]
Description=WAM Coin daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
ExecStart=$PREFIX/bin/wamd -conf=$CONF -datadir=$DATA_DIR -printtoconsole
Restart=on-failure
RestartSec=10
TimeoutStopSec=120
KillSignal=SIGTERM

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
ok "wamd.service installed"

fi   # DO_NODE

# ===========================================================================
if [ "$DO_POOL" = "1" ]; then
step "5/6  Stratum pool"
# ===========================================================================

cd "$REPO_ROOT/pool"

log "installing node modules"
npm install --omit=dev --silent || die "npm install failed"

log "building the RandomX native addon"
[ -f "$RANDOMX_DIR/build/librandomx.a" ] \
    || die "librandomx.a is missing -- run scripts/fetch-upstream.sh first"

cd native
RANDOMX_INCLUDE="$RANDOMX_DIR/src" \
RANDOMX_LIB="$RANDOMX_DIR/build/librandomx.a" \
    npx node-gyp rebuild --silent || die "the native addon failed to build"
cd ..

ok "native addon built"

log "running the pool test suite"
node test/rewards.test.js || die "the pool tests failed"

if [ ! -f config.json ]; then
    cp config.example.json config.json

    # Wire in the passwords we just generated so the pool works out of the box.
    # The pool refuses to start without a Redis password, so leaving this to
    # the operator would mean a fresh install that cannot run.
    if [ -n "${RPC_PASS:-}" ] || [ -n "${WAM_REDIS_PASS:-}" ]; then
        python3 - "$PWD/config.json" "${RPC_PASS:-}" "$NETWORK" "${WAM_REDIS_PASS:-}" <<'PY'
import json, sys
path, password, network, redis_pass = sys.argv[1:5]
with open(path) as fh:
    cfg = json.load(fh)
cfg["network"] = network
port = {"mainnet": 9556, "testnet": 19556, "regtest": 29556}[network]
for d in cfg["daemons"]:
    if password:
        d["password"] = password
    d["port"] = port
if redis_pass:
    cfg.setdefault("redis", {})["password"] = redis_pass
with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2)
PY
    fi

    # A pre-existing Redis password cannot be read back out of redis.conf
    # without root, so say plainly what is missing rather than letting the
    # pool fail at startup with a message about a file the operator did not
    # know it needed.
    if ! python3 -c "import json,sys; sys.exit(0 if json.load(open('$PWD/config.json')).get('redis',{}).get('password') else 1)" 2>/dev/null; then
        warn "pool/config.json has no redis.password. Redis already had one set,"
        warn "so it could not be generated here. Copy it out of redis.conf:"
        warn "    sudo grep '^requirepass' /etc/redis/redis.conf"
    fi
    chmod 600 config.json
    warn "created pool/config.json -- you MUST set 'poolAddress' before starting it"
else
    ok "pool/config.json already exists; leaving it alone"
fi

sudo tee /etc/systemd/system/wam-pool.service >/dev/null <<EOF
[Unit]
Description=WAM Coin stratum mining pool
After=network-online.target wamd.service redis-server.service
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$REPO_ROOT/pool
ExecStart=/usr/bin/node $REPO_ROOT/pool/server.js --config $REPO_ROOT/pool/config.json
Restart=on-failure
RestartSec=15

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
ok "wam-pool.service installed"

fi   # DO_POOL

# ===========================================================================
if [ "$DO_NODE" = "1" ]; then
step "5b/6  Network dashboard"
# ===========================================================================

# Zero npm dependencies by design -- nothing to install, nothing to build.
# It reads RPC credentials straight out of wam.conf, so there is no second
# copy of the password to keep in sync.

if command -v node >/dev/null; then
    node -e "require('$REPO_ROOT/explorer/lib/collector.js')" 2>/dev/null \
        && ok "dashboard loads cleanly" \
        || warn "dashboard modules failed to load -- check: node $REPO_ROOT/explorer/server.js"

    sudo tee /etc/systemd/system/wam-dashboard.service >/dev/null <<EOF
[Unit]
Description=WAM Network Dashboard
After=network-online.target wamd.service
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
Environment=WAM_CONF=$CONF
WorkingDirectory=$REPO_ROOT/explorer
ExecStart=/usr/bin/node $REPO_ROOT/explorer/server.js
Restart=on-failure
RestartSec=10

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    ok "wam-dashboard.service installed (binds to 127.0.0.1:8081)"
else
    warn "node is not installed; skipping the dashboard"
fi

fi   # DO_NODE (dashboard)

# ===========================================================================
step "6/6  Starting services"
# ===========================================================================

if [ "$DO_START" = "0" ]; then
    warn "--build-only: nothing was started"
else
    if [ "$DO_NODE" = "1" ]; then
        sudo systemctl enable --now wamd
        sleep 5
        if systemctl is-active --quiet wamd; then
            ok "wamd is running"
        else
            warn "wamd did not start; check: journalctl -u wamd -n 50"
        fi

        if [ -f /etc/systemd/system/wam-dashboard.service ]; then
            sudo systemctl enable --now wam-dashboard
            sleep 2
            systemctl is-active --quiet wam-dashboard \
                && ok "dashboard is running on http://127.0.0.1:8081/" \
                || warn "dashboard did not start; check: journalctl -u wam-dashboard -n 50"
        fi
    fi

    if [ "$DO_POOL" = "1" ]; then
        if grep -q "WCHANGEme" "$REPO_ROOT/pool/config.json" 2>/dev/null; then
            warn "pool NOT started: poolAddress in pool/config.json is still a placeholder"
        else
            sudo systemctl enable --now wam-pool
            sleep 3
            systemctl is-active --quiet wam-pool \
                && ok "the pool is running" \
                || warn "the pool did not start; check: journalctl -u wam-pool -n 50"
        fi
    fi
fi

# ===========================================================================
printf '\n%s%s%s\n' "$GRN" "$(printf '=%.0s' {1..74})" "$OFF"
printf '%s WAM Coin installation complete%s\n' "$GRN" "$OFF"
printf '%s%s%s\n\n' "$GRN" "$(printf '=%.0s' {1..74})" "$OFF"

cat <<EOF
  Node
    status      systemctl status wamd
    logs        journalctl -u wamd -f
    cli         wam-cli -conf=$CONF getblockchaininfo
    supply      wam-cli -conf=$CONF getsupplyinfo
    treasury    wam-cli -conf=$CONF getdevfeeinfo
    randomx     wam-cli -conf=$CONF getrandomxinfo

  Network dashboard
    open        http://127.0.0.1:8081/
    status      systemctl status wam-dashboard
    logs        journalctl -u wam-dashboard -f
    health      curl -fs localhost:8081/api/health

  Pool
    status      systemctl status wam-pool
    logs        journalctl -u wam-pool -f
    dashboard   http://localhost:8080/
    config      $REPO_ROOT/pool/config.json

  Monetary policy (audit it yourself)
    python3 scripts/verify_supply.py --schedule

  Before mainnet
    - set poolAddress in pool/config.json
    - open the stratum ports in your firewall (3333/3334/3335)
    - put the dashboard behind TLS if it is public
    - keep the founder WIF offline; it is never needed by any of this

EOF

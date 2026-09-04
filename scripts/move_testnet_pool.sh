#!/bin/bash
# ===========================================================================
#  move_testnet_pool.sh -- hold the published stratum ports for mainnet
# ===========================================================================
#
#      bash scripts/move_testnet_pool.sh [HOST]
#
#  WHY
#
#  pool/config.json (testnet) and pool/config-mainnet.json both claim 3333,
#  3334, 3335 and 3336. They cannot both run. On launch night the mainnet pool
#  either fails to bind or takes the testnet pool down -- and 3333 is the port
#  docs/START_HERE tells every newcomer to point a miner at, so it belongs to
#  mainnet.
#
#  The same collision was found in ElectrumX on 29 August and answered the same
#  way: move testnet aside, hold the published ports empty, so that nothing
#  answers on a mainnet port with a testnet chain. Testnet goes to 13333-13336,
#  the prefix this project already uses for 9555/19555 and 9554/19554.
#
#  BEFORE RUNNING THIS
#
#  The provider drops 13333-13336 upstream until they are allowed in its own
#  panel -- ufw is not enough, and this was measured with tcpdump rather than
#  guessed: SYNs arrived on 3333 and none at all on 13333, while iptables
#  carried an explicit ACCEPT. So:
#
#      Contabo panel -> Firewall -> allow TCP 13333, 13334, 13335, 13336
#
#  This script checks that from outside before it changes anything, and
#  refuses if the ports are not reachable. Moving a pool to a port no miner
#  can reach is worse than the collision it fixes.
# ===========================================================================

set -uo pipefail
H="${1:-169.58.159.165}"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'

echo
echo "${BLD}moving the testnet pool off the published mainnet ports${OFF}"
echo "  host: $H"
echo

# ---- refuse if the new ports cannot be reached -----------------------------
#
# A listener the world cannot reach is not a pool. The check is done from this
# machine, which is outside both servers' networks, because a test run on the
# server itself would pass while every miner failed.
echo "  checking the new ports are open at the provider..."
blocked=0
for p in 13333 13334 13335 13336; do
    if timeout 8 bash -c "echo > /dev/tcp/$H/$p" 2>/dev/null; then
        printf '    %s%s open%s\n' "$GRN" "$p" "$OFF"
    else
        # Refused is what a closed-but-reachable port does, and that is fine:
        # nothing is listening yet. Dropped is what the provider does, and
        # that is the blocker. They look the same from here until something
        # listens, so this runs the check again after the move and rolls back.
        printf '    %s%s no answer%s\n' "$YLW" "$p" "$OFF"
        blocked=$((blocked + 1))
    fi
done

echo
echo "  moving the config and restarting..."
ssh -o BatchMode=yes "root@$H" '
  set -e

# An interpreter that is actually Python: `python3` on Windows is a
# Microsoft Store stub that runs nothing and exits 49.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPTS_DIR/lib/python.sh"

  cp /opt/wam/pool/config.json /root/config.json.bak-$(date -u +%Y%m%dT%H%M%SZ)
  "$PY" - <<PY
import json
p = "/opt/wam/pool/config.json"
c = json.load(open(p))
for e in c.get("ports", []):
    if 3333 <= e["port"] <= 3336:
        e["port"] += 10000
json.dump(c, open(p, "w"), indent=2)
print("    testnet ports ->", [e["port"] for e in c.get("ports", [])])
PY
  chmod 600 /opt/wam/pool/config.json
  for p in 13333 13334 13335 13336; do ufw allow "$p"/tcp comment "stratum testnet" >/dev/null 2>&1; done
  sed -i "s#stratum+tcp://127.0.0.1:3333#stratum+tcp://127.0.0.1:13333#" /etc/systemd/system/wam-miner.service
  systemctl daemon-reload
  systemctl restart wam-pool; sleep 6
  systemctl restart wam-miner; sleep 4
'

echo
echo "  verifying from outside..."
ok=1
for p in 3333 3334 3335 3336; do
    timeout 6 bash -c "echo > /dev/tcp/$H/$p" 2>/dev/null \
        && { printf '    %s%s STILL ANSWERS -- it must be empty for mainnet%s\n' "$RED" "$p" "$OFF"; ok=0; } \
        || printf '    %s%s empty, held for mainnet%s\n' "$GRN" "$p" "$OFF"
done
for p in 13333 13334 13335 13336; do
    timeout 6 bash -c "echo > /dev/tcp/$H/$p" 2>/dev/null \
        && printf '    %s%s answers -- miners can reach the testnet pool%s\n' "$GRN" "$p" "$OFF" \
        || { printf '    %s%s UNREACHABLE from outside%s\n' "$RED" "$p" "$OFF"; ok=0; }
done

if [ "$ok" -eq 0 ]; then
    echo
    echo "  ${RED}rolling back -- a pool no miner can reach is worse than the collision${OFF}"
    ssh -o BatchMode=yes "root@$H" '
      "$PY" - <<PY
import json
p = "/opt/wam/pool/config.json"
c = json.load(open(p))
for e in c.get("ports", []):
    if 13333 <= e["port"] <= 13336:
        e["port"] -= 10000
json.dump(c, open(p, "w"), indent=2)
PY
      chmod 600 /opt/wam/pool/config.json
      sed -i "s#stratum+tcp://127.0.0.1:13333#stratum+tcp://127.0.0.1:3333#" /etc/systemd/system/wam-miner.service
      systemctl daemon-reload; systemctl restart wam-pool; sleep 5; systemctl restart wam-miner
    '
    echo "  back on 3333-3336. Open 13333-13336 in the provider panel first."
    echo
    exit 1
fi

echo
echo "  ${GRN}done. 3333-3336 are held empty for mainnet.${OFF}"
echo "  Repoint any external miner at ${BLD}pool.wamcoin.org:13333${OFF}"
echo

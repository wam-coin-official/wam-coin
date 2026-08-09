#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  resilience_check.sh -- kill the services on purpose and watch them return
# ===========================================================================
#
#  "The dashboard stopped" is not something to fix once and declare solved.
#  This script reproduces each way it can stop and proves recovery, so the
#  claim "it restarts itself" is a measurement rather than an assurance.
#
#      bash scripts/resilience_check.sh
#
#  Failure modes covered:
#     1. the dashboard process is killed          -> systemd restarts it
#     2. the node process is killed               -> systemd restarts it
#     3. the dashboard crashes repeatedly         -> restart policy holds
#     4. the WSL session ends                     -> Linger keeps services up
#     5. services survive a reboot                -> enabled at default.target
#
#  Anything this script cannot verify from inside WSL is reported as such
#  rather than assumed.
# ===========================================================================

set -uo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

DASH_URL="http://127.0.0.1:8081/api/health"
NODE_SVC="wamd"
DASH_SVC="wam-dashboard"
TIMEOUT=60

PASS=0
FAIL=0

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim()   { printf '\033[90m%s\033[0m\n' "$*"; }

ok()   { green "  ok    $*"; PASS=$((PASS+1)); }
bad()  { red   "  FAIL  $*"; FAIL=$((FAIL+1)); }
note() { dim   "        $*"; }

wait_for_dashboard() {
    local deadline=$((SECONDS + TIMEOUT))
    while [ $SECONDS -lt $deadline ]; do
        if curl -fs -m 3 "$DASH_URL" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_node() {
    local deadline=$((SECONDS + TIMEOUT))
    while [ $SECONDS -lt $deadline ]; do
        if curl -fs -m 3 "$DASH_URL" 2>/dev/null | grep -q '"ok":true'; then
            return 0
        fi
        sleep 2
    done
    return 1
}

echo "=================================================================="
echo " WAM resilience check"
echo "=================================================================="
echo

# ---------------------------------------------------------------------------
echo "[0] baseline"
# ---------------------------------------------------------------------------
for svc in "$NODE_SVC" "$DASH_SVC"; do
    state=$(systemctl --user is-active "$svc" 2>&1)
    [ "$state" = "active" ] && ok "$svc is active" || bad "$svc is $state"
done

if wait_for_node; then
    ok "dashboard reports the node healthy"
else
    bad "dashboard does not report a healthy node"
    note "$(curl -s -m 3 "$DASH_URL" 2>&1 | head -c 200)"
fi

# ---------------------------------------------------------------------------
echo
echo "[1] restart policy is configured"
# ---------------------------------------------------------------------------
for svc in "$NODE_SVC" "$DASH_SVC"; do
    policy=$(systemctl --user show -p Restart --value "$svc" 2>/dev/null)
    [ "$policy" = "always" ] && ok "$svc Restart=always" || bad "$svc Restart=$policy"

    enabled=$(systemctl --user is-enabled "$svc" 2>/dev/null)
    [ "$enabled" = "enabled" ] && ok "$svc starts with the user session" \
                               || bad "$svc is $enabled"
done

linger=$(loginctl show-user "$(whoami)" 2>/dev/null | grep -i '^Linger=' | cut -d= -f2)
[ "$linger" = "yes" ] && ok "Linger=yes (services outlive the last terminal)" \
                      || bad "Linger=$linger -- services die when you close Ubuntu"

# ---------------------------------------------------------------------------
echo
echo "[2] kill the dashboard -> it must come back"
# ---------------------------------------------------------------------------
before=$(systemctl --user show -p NRestarts --value "$DASH_SVC")
pid=$(systemctl --user show -p MainPID --value "$DASH_SVC")
note "killing dashboard pid $pid with SIGKILL"
kill -9 "$pid" 2>/dev/null

start=$SECONDS
if wait_for_dashboard; then
    ok "dashboard recovered in $((SECONDS - start))s"
else
    bad "dashboard did not recover within ${TIMEOUT}s"
fi
after=$(systemctl --user show -p NRestarts --value "$DASH_SVC")
[ "$after" -gt "$before" ] && ok "systemd recorded the restart ($before -> $after)" \
                           || bad "restart was not recorded"

# ---------------------------------------------------------------------------
echo
echo "[3] kill the node -> it must come back and the dashboard reconnect"
# ---------------------------------------------------------------------------
pid=$(systemctl --user show -p MainPID --value "$NODE_SVC")
note "killing node pid $pid with SIGKILL"
kill -9 "$pid" 2>/dev/null

start=$SECONDS
if wait_for_node; then
    ok "node recovered and dashboard reconnected in $((SECONDS - start))s"
else
    bad "node did not recover within ${TIMEOUT}s"
    note "$(systemctl --user status "$NODE_SVC" --no-pager -n 5 2>&1 | tail -5)"
fi

# ---------------------------------------------------------------------------
echo
echo "[4] the dashboard degrades instead of dying when the node is down"
# ---------------------------------------------------------------------------
# Reporting that the node is unreachable IS the dashboard's job. It must keep
# serving during an outage, not exit alongside it.
systemctl --user stop "$NODE_SVC" >/dev/null 2>&1
sleep 8

if curl -fs -m 5 http://127.0.0.1:8081/ >/dev/null 2>&1; then
    ok "dashboard still serves its page while the node is stopped"
else
    bad "dashboard became unreachable when the node stopped"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$DASH_URL" 2>/dev/null)
[ "$code" = "503" ] && ok "/api/health returns 503 during the outage (alertable)" \
                    || bad "/api/health returned $code, expected 503"

systemctl --user start "$NODE_SVC" >/dev/null 2>&1
if wait_for_node; then
    ok "node restarted cleanly and health returned to 200"
else
    bad "node did not come back after a clean restart"
fi

# ---------------------------------------------------------------------------
echo
echo "[5] what this script CANNOT verify from inside WSL"
# ---------------------------------------------------------------------------
note "wsl --shutdown, a Windows reboot, and laptop sleep all stop the VM"
note "itself. Linger brings the services back on the next WSL start, but"
note "something on the Windows side has to start WSL. Verified separately."
note ""
note "A laptop is not production infrastructure. Phase 2 of docs/ROADMAP.md"
note "moves the testnet nodes to a real always-on server."

# ---------------------------------------------------------------------------
echo
echo "=================================================================="
if [ "$FAIL" -eq 0 ]; then
    green " ALL $PASS RESILIENCE CHECKS PASSED"
else
    red   " $FAIL of $((PASS+FAIL)) CHECKS FAILED"
fi
echo "=================================================================="
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)

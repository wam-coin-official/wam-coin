#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  ops.py -- the operator's dashboard, on the operator's own machine
# ===========================================================================
#
#      python3 ops/ops.py
#      then open http://127.0.0.1:8787
#
#  WHY IT RUNS HERE AND NOT ON A SERVER
#
#  A monitoring page shows which service is down, which machine is short of
#  memory, what hour the backup runs and which node is behind. That is what
#  makes it useful, and it is also a map for anyone who wants to attack the
#  network: it names the weak machine and the unwatched hour.
#
#  Served from a server it needs a public address, a password, TLS, and it
#  becomes one more door into a machine that holds money. Run here it needs
#  none of those, because it is not on the internet at all. It binds to
#  127.0.0.1, which no other machine can reach -- not the café wifi, not the
#  router, not anyone.
#
#  WHAT IT MUST NEVER DO, AND DOES NOT
#
#  It runs read-only commands over the ssh key already on this machine. It
#  writes nothing to any server, stores no credential, and opens no port
#  beyond the loopback.
#
#  THE FOUR RULES AGAINST LYING
#
#  The founder put it plainly: "the report sometimes lies". A green panel
#  over a broken system is worse than no panel, because it buys calm that
#  was not earned. Three times in one day this project has had exactly that
#  -- a sweep reporting 21 passed while the backups had been dead for three
#  days; a version check going green because the outdated node happened to
#  be offline in that minute; two of my own measurements reporting the wrong
#  answer about something that was working.
#
#  So:
#
#    1. Every value carries the moment it was measured. Not "backups ok" but
#       "backups, 6h ago". A stale number shown as current is the ordinary
#       way a dashboard lies.
#    2. Unreachable is not healthy. When a host cannot be reached its panel
#       goes grey and says so, rather than holding the last good reading.
#    3. The page shows its own age. If the collector dies the page freezes,
#       and the age is what tells you rather than the stillness.
#    4. Nothing is inferred. What was not measured is not displayed.
#
#  It runs the same check scripts the sweep runs, rather than reimplementing
#  them, so that this page and the sweep cannot ever disagree about what is
#  true.
# ===========================================================================

import http.server
import json
import os
import re
import shlex
import socketserver
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
# 9787 rather than the obvious 8787: that one is already taken on the
# founder's laptop by another of his applications, and a dashboard that
# silently shows somebody else's page is worse than one that will not start.
PORT = int(os.environ.get("WAM_OPS_PORT", "9787"))
STATE = os.path.join(HERE, "state.json")

HOSTS = [
    ("France", "169.58.159.165"),
    ("Singapore", "5.223.52.200"),
]

# Services that are expected on a host. A host that has never run one is not
# failing by not running it -- the pool lives on one machine only -- so the
# collector reports what it finds rather than what it hoped to find.
SERVICES = [
    "wamd", "wam-electrumx@testnet", "wam-pool", "wam-dashboard",
    "wam-announce", "wam-miner", "wam-backup.timer",
    "wam-reorg-watch@testnet.timer", "wam-version-watch.timer",
    "wamd-mainnet", "wam-electrumx@mainnet",
]

_state = {"generated": 0, "hosts": {}, "checks": {}, "errors": []}
_lock = threading.Lock()


def rsh(host, cmd, timeout=45):
    """One read-only command on a host. Returns (rc, stdout)."""
    try:
        p = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
             "-o", "StrictHostKeyChecking=accept-new", f"root@{host}", cmd],
            capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except Exception as e:
        return 255, f"{type(e).__name__}: {e}"


def collect_host(name, ip):
    """Everything about one machine, in one round trip.

    One ssh call rather than ten: ten calls take ten times as long and can
    disagree with each other, because the machine changes between them.
    """
    script = r"""
set -u
echo "###os"; . /etc/os-release 2>/dev/null; echo "$PRETTY_NAME"
echo "###uptime"; cut -d. -f1 /proc/uptime
echo "###load"; cut -d' ' -f1-3 /proc/loadavg
echo "###mem"; free -m | awk '/Mem:/{print $2, $7} /Swap:/{print $2, $3}'
echo "###disk"; df -BM --output=avail,size / | tail -1 | tr -d 'M'
echo "###git"; git -C /opt/wam rev-parse --short HEAD 2>/dev/null
echo "###height"; /opt/wam-current-bin/wam-cli -testnet getblockcount 2>/dev/null
echo "###tip"; /opt/wam-current-bin/wam-cli -testnet getbestblockhash 2>/dev/null
echo "###peers"; /opt/wam-current-bin/wam-cli -testnet getconnectioncount 2>/dev/null
echo "###services"
for u in %s; do
  # is-active prints "inactive" AND exits non-zero, so the obvious
  # `$(... || echo unknown)` yields "inactive unknown" on one line and the
  # field split reads the wrong word. Capture first, then decide.
  a=$(systemctl is-active "$u" 2>/dev/null); [ -n "$a" ] || a=unknown
  e=$(systemctl is-enabled "$u" 2>/dev/null); [ -n "$e" ] || e=-
  printf '%%s %%s %%s\n' "$u" "$a" "$e"
done
echo "###backup"; ls -t /root/backups/*.gpg 2>/dev/null | head -1 | xargs -r stat -c %%Y
echo "###alarms"; ls /var/lib/wam-reorg/ALARM-* 2>/dev/null | wc -l
echo "###motd"; [ -f /etc/update-motd.d/98-wam-version ] && echo yes || echo no
# The state of the SERVICE, not of the timer above it. This panel read only
# is-active on the timer, and a timer stays active however often the service
# under it fails -- which is how wam-reorg-watch failed on both machines at
# 03:11 and 03:47 UTC on 1 September 2026 and this page stayed green for ten
# hours. The leading bullet comes and goes with the systemd version, so strip
# everything before the name instead of counting columns.
echo "###failed"; systemctl list-units --state=failed --plain --no-legend --no-pager 2>/dev/null \
  | sed 's/^[^A-Za-z0-9]*//' | awk '{print $1}' | head -20
# Planned work, declared with wam-maint. It silences nothing; the panel shows
# it so a red line during a reboot reads as expected rather than as a fault --
# and so that a red line with NO declared work reads as what it is.
# Every literal percent in here must be doubled -- including in comments.
# This whole string goes through Python's %% operator to substitute the
# service list, so a lone %%d is eaten there and never reaches the shell.
# Adding the block below without doubling them broke every host card with
# "not enough arguments for format string", and the panel then showed both
# machines as unreachable -- which reads exactly like two servers being down.
# The first attempt at this comment had single percents in it and re-broke
# the same thing while explaining it.
echo "###maint"; [ -f /var/lib/wam-login-watch/maintenance.json ] && \
  python3 -c "
import json,time
m=json.load(open('/var/lib/wam-login-watch/maintenance.json'))
left=int(float(m.get('until',0))-time.time())
print('%%d %%s'%%(left,m.get('reason','?')) if left>0 else '')" 2>/dev/null
echo "###end"
""" % " ".join(SERVICES)

    rc, out = rsh(ip, script, timeout=60)
    now = int(time.time())
    if rc != 0 or "###end" not in out:
        return {"name": name, "ip": ip, "reachable": False, "checked": now,
                "why": (out or "no answer").strip()[:200]}

    parts = {}
    key = None
    for line in out.splitlines():
        if line.startswith("###"):
            key = line[3:]
            parts[key] = []
        elif key:
            parts[key].append(line)

    def one(k, cast=str, default=None):
        v = parts.get(k) or []
        v = [x for x in v if x.strip()]
        if not v:
            return default
        try:
            return cast(v[0].strip())
        except Exception:
            return default

    mem = (parts.get("mem") or ["", ""])
    mem_total = mem_avail = swap_total = swap_used = None
    if len(mem) >= 1 and mem[0].split():
        f = mem[0].split()
        mem_total, mem_avail = int(f[0]), int(f[1])
    if len(mem) >= 2 and mem[1].split():
        f = mem[1].split()
        swap_total, swap_used = int(f[0]), int(f[1])

    disk = (parts.get("disk") or [""])[0].split()
    services = {}
    for line in parts.get("services", []):
        f = line.split()
        if len(f) >= 3:
            services[f[0]] = {"active": f[1], "enabled": f[2]}

    return {
        "name": name, "ip": ip, "reachable": True, "checked": now,
        "os": one("os"),
        "uptimeSeconds": one("uptime", int),
        "load": (parts.get("load") or [""])[0].strip() or None,
        "memTotalMb": mem_total, "memAvailMb": mem_avail,
        "swapTotalMb": swap_total, "swapUsedMb": swap_used,
        "diskAvailMb": int(disk[0]) if len(disk) > 1 else None,
        "diskTotalMb": int(disk[1]) if len(disk) > 1 else None,
        "git": one("git"),
        "height": one("height", int),
        "tip": one("tip"),
        "peers": one("peers", int),
        "services": services,
        "newestBackup": one("backup", int),
        "reorgAlarms": one("alarms", int, 0),
        "versionNotice": one("motd") == "yes",
        "failedUnits": [x.strip() for x in parts.get("failed", []) if x.strip()],
        "maintenance": one("maint"),
    }


WINDOWS = os.name == "nt"

# Where this repository lives as seen from inside WSL, for the checks that are
# shell scripts. Derived, not hardcoded: C:\wam-blockchain-core -> /mnt/c/...
def _wsl_path(p):
    d, rest = os.path.splitdrive(os.path.abspath(p))
    return "/mnt/" + d[0].lower() + rest.replace("\\", "/")


def portable(argv):
    """The same check, runnable from a Windows process.

    The dashboard now serves the page from Windows rather than from inside
    WSL, because a page bound to 127.0.0.1 inside the WSL virtual machine is
    not reliably reachable from the Windows browser -- on 2 September 2026 it
    was not reachable at all, by localhost or by the VM's own address, and the
    one tool whose job is to say when something is wrong was itself
    unreachable with nothing to announce it.

    But half of these checks are shell scripts, and Windows has no bash. So
    the HTTP server runs natively and the shell checks are handed to WSL,
    which is where they were written to run. Python checks run under the
    Windows interpreter directly.
    """
    if not WINDOWS:
        return argv, REPO
    if argv and argv[0] == "bash":
        inner = " ".join(shlex.quote(a) for a in argv[1:])
        return (["wsl", "-e", "bash", "-lc",
                 f"cd {shlex.quote(_wsl_path(REPO))} && bash {inner}"], None)
    return argv, REPO


def run_check(name, argv, timeout=240):
    """Run one of the repository's own check scripts and keep its verdict.

    The exit code is the verdict -- these scripts are written that way -- and
    the text is kept so the page can show why. Running them rather than
    reimplementing them is the point: this page and the sweep read the same
    instrument, so they cannot disagree about what is true.
    """
    started = int(time.time())
    argv, cwd = portable(argv)
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                           timeout=timeout)
        rc, out = p.returncode, (p.stdout + p.stderr)
    except subprocess.TimeoutExpired:
        return {"name": name, "status": "unknown", "ran": started,
                "detail": f"did not finish within {timeout}s -- "
                          f"that is not a pass"}
    except Exception as e:
        return {"name": name, "status": "unknown", "ran": started,
                "detail": f"could not run: {type(e).__name__}: {e}"}

    clean = re.sub(r"\x1b\[[0-9;]*m", "", out)
    lines = [l.rstrip() for l in clean.splitlines() if l.strip()]
    return {
        "name": name,
        "status": "ok" if rc == 0 else "bad",
        "exit": rc,
        "ran": started,
        "detail": "\n".join(lines[-14:]),
    }


FAST_EVERY = 60

# Ten minutes rather than fifteen. The heavy checks each open their own ssh
# connections and cannot run every minute, but at fifteen a verdict could
# sit twelve minutes behind the facts printed directly above it -- the cards
# saying both machines run the same commit while the check below still read
# FAILING. The age beside each verdict makes that legible rather than
# misleading, which is the point of showing it, but a shorter cycle means
# the two agree sooner and the reader has less to reconcile.
SLOW_EVERY = 600

CHECKS = [
    ("backups", [sys.executable, "scripts/check_backups.py",
                 "169.58.159.165", "5.223.52.200"], 150),
    ("no block was un-confirmed", [sys.executable, "scripts/check_reorg.py",
                                   "--network", "testnet", "--state-dir",
                                   os.path.expanduser("~/.wam-reorg"),
                                   "169.58.159.165", "5.223.52.200"], 180),
    ("everyone can follow mainnet", [sys.executable,
                                     "scripts/check_peer_versions.py",
                                     "--node", "169.58.159.165",
                                     "--network", "testnet"], 200),
    ("nodes agree", ["bash", "scripts/check_nodes_agree.sh",
                     "169.58.159.165", "5.223.52.200"], 150),
    ("deployed code is origin/main", ["bash", "scripts/check_deployed_code.sh",
                                      "169.58.159.165", "5.223.52.200"], 150),
    ("the repository agrees with itself", ["bash", "scripts/audit_repo.sh"], 200),
    ("listing entries match source", [sys.executable,
                                      "scripts/check_listing_entry.py"], 120),
]


def collector():
    last_slow = 0
    while True:
        start = time.time()
        hosts = {}
        for name, ip in HOSTS:
            try:
                hosts[ip] = collect_host(name, ip)
            except Exception as e:
                hosts[ip] = {"name": name, "ip": ip, "reachable": False,
                             "checked": int(time.time()),
                             "why": f"{type(e).__name__}: {e}"}

        with _lock:
            _state["hosts"] = hosts
            _state["generated"] = int(time.time())

        if time.time() - last_slow > SLOW_EVERY:
            last_slow = time.time()
            for name, argv, timeout in CHECKS:
                r = run_check(name, argv, timeout)
                with _lock:
                    _state["checks"][name] = r
            with _lock:
                _state["generated"] = int(time.time())

        try:
            with _lock:
                tmp = STATE + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(_state, f)
                os.replace(tmp, STATE)
        except OSError:
            pass

        time.sleep(max(5, FAST_EVERY - (time.time() - start)))


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=HERE, **kw)

    def do_GET(self):
        if self.path.startswith("/state.json"):
            with _lock:
                body = json.dumps(_state).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path in ("/", ""):
            self.path = "/index.html"
        return super().do_GET()

    def log_message(self, *a):
        pass


def main():
    threading.Thread(target=collector, daemon=True).start()
    # 127.0.0.1 and nothing else. Binding to 0.0.0.0 here would put the map
    # of this network's weak points on whatever wifi this laptop is using.
    with socketserver.ThreadingTCPServer(("127.0.0.1", PORT), Handler) as srv:
        srv.allow_reuse_address = True
        print(f"  WAM ops dashboard  ->  http://127.0.0.1:{PORT}")
        print(f"  reachable from this machine only. Ctrl-C to stop.\n")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\n  stopped.")


if __name__ == "__main__":
    main()

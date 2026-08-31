#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  daily_report.py -- the one that comes to you, rather than waiting to be
#                     asked
# ===========================================================================
#
#      python3 scripts/daily_report.py            # gather and send
#      python3 scripts/daily_report.py --dry-run  # print it, send nothing
#
#  WHY THIS EXISTS
#
#  Everything else this repository checks writes into a journal or a file on
#  a server. That is fine while somebody is looking, and the failures that
#  hurt are precisely the ones nobody is looking at: the nightly backup died
#  on both machines on 23 August and stayed dead until the 26th, while every
#  check that ran said the timer was armed and the sweep reported 21 passed.
#
#  A dashboard does not fix that either, because a dashboard also waits to
#  be opened. What is missing is something that arrives.
#
#  WHAT STOPS IT LYING
#
#  The founder's objection, in his words: "the report sometimes lies". A
#  green message over a broken system is worse than none, because it buys
#  calm that was not earned. Four things answer that:
#
#    1. A SEQUENCE NUMBER. Each report is numbered. If #12 arrives and then
#       #14, report #13 never came -- which means the machine that sends
#       them was down, and the absence is itself the alarm. Silence is the
#       one failure a monitoring system cannot report on its own, so the
#       numbering is what makes silence visible.
#    2. AGES, NOT ADJECTIVES. Not "backups ok" but "backups 6h". A value
#       whose age is hidden is a value you cannot judge.
#    3. COULD-NOT-CHECK IS ITS OWN WORD. A check that failed to run is
#       neither a pass nor a failure and is listed separately, because
#       counting it either way is a lie in one direction or the other.
#    4. IT RUNS THE SAME CHECKS AS THE SWEEP. Not a second implementation
#       that will disagree one day.
#
#  It goes to one private chat, never to the announcement channel. An
#  operations report names the weakest machine and the hour nobody watches,
#  and that is a map for whoever wants to attack this network.
# ===========================================================================

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONF = "/etc/wam/announce.json"
STATE = "/var/lib/wam-report/state.json"

HOSTS = [("France", "169.58.159.165"), ("Singapore", "5.223.52.200")]

CHECKS = [
    ("backups", [sys.executable, "scripts/check_backups.py",
                 "169.58.159.165", "5.223.52.200"], 180),
    ("no block un-confirmed", [sys.executable, "scripts/check_reorg.py",
                               "--network", "testnet", "--state-dir",
                               "/var/lib/wam-reorg-report",
                               "169.58.159.165", "5.223.52.200"], 200),
    ("everyone can follow mainnet",
     [sys.executable, "scripts/check_peer_versions.py",
      "--node", "169.58.159.165", "--network", "testnet"], 200),
    ("nodes agree", ["bash", "scripts/check_nodes_agree.sh",
                     "169.58.159.165", "5.223.52.200"], 180),
    ("deployed code is origin/main",
     ["bash", "scripts/check_deployed_code.sh",
      "169.58.159.165", "5.223.52.200"], 180),
    ("repository agrees with itself", ["bash", "scripts/audit_repo.sh"], 200),
    ("listing entries match source",
     [sys.executable, "scripts/check_listing_entry.py"], 150),
    ("electrum answers", [sys.executable, "scripts/check_electrum.py",
                          "--node", "169.58.159.165", "--network", "testnet",
                          "electrum.wamcoin.org", "electrum2.wamcoin.org"], 240),
    ("pool gives work and pays",
     [sys.executable, "scripts/check_pool.py", "--node", "169.58.159.165",
      "--network", "testnet"], 240),
]


def rsh(host, cmd, timeout=60):
    try:
        p = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
             f"root@{host}", cmd], capture_output=True, text=True,
            timeout=timeout)
        return p.returncode, p.stdout
    except Exception as e:
        return 255, f"{type(e).__name__}: {e}"


def host_facts(name, ip):
    rc, out = rsh(ip, r"""
echo "###h"; /opt/wam-current-bin/wam-cli -testnet getblockcount 2>/dev/null
echo "###p"; /opt/wam-current-bin/wam-cli -testnet getconnectioncount 2>/dev/null
echo "###m"; free -m | awk '/Mem:/{print $7, $2}'
echo "###s"; free -m | awk '/Swap:/{print $2}'
echo "###d"; df -BG --output=avail / | tail -1 | tr -dc 0-9
echo "###b"; ls -t /root/backups/*.gpg 2>/dev/null | head -1 | xargs -r stat -c %Y
echo "###a"; ls /var/lib/wam-reorg/ALARM-* 2>/dev/null | wc -l
echo "###g"; git -C /opt/wam rev-parse --short HEAD 2>/dev/null
echo "###end"
""")
    if rc != 0 or "###end" not in out:
        return {"name": name, "up": False, "why": (out or "").strip()[:120]}

    f = {}
    key = None
    for line in out.splitlines():
        if line.startswith("###"):
            key = line[3:]
            f[key] = []
        elif key:
            f[key].append(line.strip())

    def g(k):
        v = [x for x in (f.get(k) or []) if x]
        return v[0] if v else None

    mem = (g("m") or "").split()
    return {
        "name": name, "up": True,
        "height": g("h"), "peers": g("p"),
        "memFree": mem[0] if mem else None,
        "memTotal": mem[1] if len(mem) > 1 else None,
        "swap": g("s"), "diskFreeG": g("d"),
        "backup": int(g("b")) if (g("b") or "").isdigit() else None,
        "alarms": g("a"), "git": g("g"),
    }


def run_check(name, argv, timeout):
    try:
        p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True,
                           timeout=timeout)
        rc, out = p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return name, "unknown", f"did not finish in {timeout}s"
    except Exception as e:
        return name, "unknown", f"{type(e).__name__}: {e}"

    clean = re.sub(r"\x1b\[[0-9;]*m", "", out)
    fails = [l.strip() for l in clean.splitlines()
             if re.search(r"\bFAIL\b", l)]
    detail = fails[0][:220] if fails else (clean.strip().splitlines() or [""])[-1][:220]
    return name, ("ok" if rc == 0 else "bad"), detail


def ago(ts):
    if not ts:
        return "never"
    d = int(time.time()) - int(ts)
    if d < 3600:
        return f"{d // 60}m"
    if d < 86400:
        return f"{d // 3600}h"
    return f"{d // 86400}d"


def next_number():
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE) as f:
            n = json.load(f).get("n", 0)
    except (OSError, ValueError):
        n = 0
    n += 1
    try:
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"n": n, "sent": int(time.time())}, f)
        os.replace(tmp, STATE)
    except OSError:
        pass
    return n


def build(n):
    hosts = [host_facts(name, ip) for name, ip in HOSTS]
    results = [run_check(*c) for c in CHECKS]

    bad = [r for r in results if r[1] == "bad"]
    unknown = [r for r in results if r[1] == "unknown"]
    down = [h for h in hosts if not h["up"]]

    L = []
    L.append(f"WAM ops #{n} — {time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime())}")
    L.append("")

    if down:
        L.append(f"{len(down)} MACHINE(S) UNREACHABLE")
    elif bad:
        L.append(f"{len(bad)} check(s) failing")
    elif unknown:
        L.append(f"all checks passed, {len(unknown)} could not run")
    else:
        L.append("all clear")
    L.append("")

    for h in hosts:
        if not h["up"]:
            L.append(f"{h['name']}: UNREACHABLE — {h.get('why', '')}")
            continue
        line = (f"{h['name']}: height {h['height']}, {h['peers']} peers, "
                f"{h['memFree']}/{h['memTotal']} MB free, {h['diskFreeG']}G disk, "
                f"backup {ago(h['backup'])} ago")
        if h.get("swap") in ("0", None):
            line += ", no swap"
        if (h.get("alarms") or "0") != "0":
            line += f", {h['alarms']} REORG ALARM(S) UNREAD"
        L.append(line)
    L.append("")

    if bad:
        L.append("failing:")
        for name, _, detail in bad:
            L.append(f"  {name} — {detail}")
        L.append("")
    if unknown:
        # Neither a pass nor a failure. Counted as either one, it is a lie in
        # one direction or the other.
        L.append("could not check (this is not a pass):")
        for name, _, detail in unknown:
            L.append(f"  {name} — {detail}")
        L.append("")

    okc = len([r for r in results if r[1] == "ok"])
    L.append(f"{okc} of {len(results)} checks passed.")
    L.append("")
    L.append("If a number is skipped, that report never arrived and the "
             "machine that sends them was down.")
    return "\n".join(L)


def send(text, dry):
    cfg = json.load(open(CONF))
    chat = cfg.get("opsChatId")
    token = cfg.get("telegram", {}).get("token")
    if dry or not chat or not token:
        print(text)
        if not dry:
            print("\n(no opsChatId or token configured -- nothing sent)")
        return 0
    data = urllib.parse.urlencode({
        "chat_id": chat, "text": text, "disable_web_page_preview": "true",
    }).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage", data=data)
    with urllib.request.urlopen(req, timeout=30) as f:
        return 0 if json.load(f).get("ok") else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true",
                    help="print the report, send nothing, and do not consume "
                         "a sequence number")
    a = ap.parse_args()

    if a.dry_run:
        try:
            with open(STATE) as f:
                n = json.load(f).get("n", 0) + 1
        except (OSError, ValueError):
            n = 1
    else:
        n = next_number()

    return send(build(n), a.dry_run)


if __name__ == "__main__":
    sys.exit(main())

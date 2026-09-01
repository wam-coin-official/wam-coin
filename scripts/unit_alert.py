#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  unit_alert.py -- say it out loud when a check stops working
# ===========================================================================
#
#      python3 scripts/unit_alert.py wam-reorg-watch@testnet.service
#
#  Wired in as OnFailure= on every unit that watches something. systemd runs
#  it with the failed unit's name, and it sends one message naming the unit,
#  the exit status and the last few lines it printed.
#
#  WHY THIS EXISTS
#
#  Three times now a service in this project has failed and stayed failed
#  while everything looked healthy:
#
#    * wam-backup, from 23 August -- every nightly run failed, the timer
#      stayed green, and there was nothing to restore from.
#    * wam-reorg-watch, 1 September 03:11 UTC -- the command it builds grew
#      with the chain until the kernel refused it. For ten and a half hours
#      the question "did a block that was confirmed stop being confirmed"
#      was not asked at all, on either machine.
#    * the same watcher on Singapore, 03:47 UTC, for the same reason.
#
#  Each was found by a person looking, not by the system saying so. The
#  dashboard showed the TIMER, which was active, and a timer stays active
#  however often the service under it fails. Nothing anywhere read
#  `systemctl --failed`.
#
#  That is the failure worth fixing, more than any of the three bugs: a
#  monitor whose own breakage is silent reports health it never checked, and
#  is then worth less than no monitor at all, because it is believed.
#
#  It is deliberately not clever. It sends the unit name and the tail of the
#  journal. Working out what went wrong is a person's job; knowing that
#  something did is the machine's.
# ===========================================================================

import subprocess
import sys

from wamnotify import send


def prop(unit, name):
    try:
        return subprocess.run(["systemctl", "show", unit, "-p", name,
                               "--value"], capture_output=True, text=True,
                              timeout=20).stdout.strip()
    except Exception:
        return ""


def tail(unit, n=12):
    try:
        out = subprocess.run(["journalctl", "-u", unit, "-n", str(n),
                              "--no-pager", "-o", "cat"],
                             capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return ""
    keep = [l for l in out.splitlines()
            if l.strip() and not l.startswith("Starting ")
            and "Consumed" not in l]
    return "\n".join(keep[-6:])


def main():
    if len(sys.argv) < 2:
        print("usage: unit_alert.py <unit>", file=sys.stderr)
        return 2
    unit = sys.argv[1]
    dry = "--dry-run" in sys.argv

    host = open("/etc/hostname").read().strip() if not dry else "test"
    status = prop(unit, "ExecMainStatus") or "?"
    result = prop(unit, "Result") or "?"

    body = tail(unit)
    text = (f"ALARM  {unit} FAILED on {host} "
            f"(result={result}, exit={status}).\n"
            f"Whatever that unit was watching has not been watched since it "
            f"started failing.\n")
    if body:
        text += "\nlast lines:\n" + body

    send(text, dry)
    return 0


if __name__ == "__main__":
    sys.exit(main())

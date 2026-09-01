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

import json
import os
import subprocess
import sys
import time

from wamnotify import send

STATE = "/var/lib/wam-login-watch/alerted.json"

# A unit with Restart=always that cannot start fails, restarts, and fails
# again, for ever. wam-electrumx -- a dead leftover unit pointing at an
# environment file that the per-network install had moved -- had done it 4738
# times on Singapore before anyone noticed, because nobody was listening.
#
# The first version of this file sent one message per failure. Within three
# minutes of being wired up it had sent that loop straight to a telephone.
# The rule the login watcher was built on -- an alarm that fires a hundred
# times a day is read for two days and ignored for ever after -- applies to
# the alerter itself, and it was written by the same person who then did not
# apply it.
#
# So: the first failure of a unit is sent at once. After that it is counted,
# and one line an hour says it is still failing and how many times. Nothing
# is lost and the telephone stays readable.
COOLDOWN = 3600


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


def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save(s):
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(s, f)
        os.replace(tmp, STATE)
    except OSError:
        pass


def due(unit, now, state):
    """Send now, or count it and stay quiet.

    Returns (send_it, how_many_since_the_last_one).
    """
    e = state.get(unit)
    if not e or now - e.get("last_sent", 0) >= COOLDOWN:
        state[unit] = {"last_sent": now, "since": 0,
                       "first": (e or {}).get("first", now)}
        return True, (e or {}).get("since", 0)
    e["since"] = e.get("since", 0) + 1
    state[unit] = e
    return False, e["since"]


def main():
    if len(sys.argv) < 2:
        print("usage: unit_alert.py <unit>", file=sys.stderr)
        return 2
    unit = sys.argv[1]
    dry = "--dry-run" in sys.argv

    host = open("/etc/hostname").read().strip() if not dry else "test"
    status = prop(unit, "ExecMainStatus") or "?"
    result = prop(unit, "Result") or "?"

    now = int(time.time())
    state = {} if dry else load()
    send_it, suppressed = due(unit, now, state)
    if not dry:
        save(state)

    if not send_it:
        print(f"{unit} failed again ({suppressed} since the last message); "
              f"quiet until the hour is up")
        return 0

    if suppressed:
        text = (f"ALARM  {unit} is STILL FAILING on {host} "
                f"(result={result}, exit={status}) — {suppressed} more "
                f"failure(s) in the last hour.\n")
    else:
        text = (f"ALARM  {unit} FAILED on {host} "
                f"(result={result}, exit={status}).\n"
                f"Whatever that unit was watching has not been watched since "
                f"it started failing.\n")
    text += ("Nothing will tell you when it recovers — this only speaks on "
             "failure.\n")

    body = tail(unit)
    if body:
        text += "\nlast lines:\n" + body

    send(text, dry)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_backups.py -- is there a recent backup, and did the last run work?
# ===========================================================================
#
#      python3 scripts/check_backups.py HOST [HOST ...]
#      python3 scripts/check_backups.py --max-age-hours 36 HOST
#
#  WHY THIS EXISTS
#
#  On 26 August the sweep reported 21 checks passed. The nightly backup had
#  failed on both servers every night since 23 August, and no check anywhere
#  asked. It was found by a person looking at disk usage for an unrelated
#  reason.
#
#  The failure itself was a one-line contradiction in the unit: the header
#  said the script must reach the node's RPC socket, and PrivateNetwork=yes
#  three lines below took the socket away. Every run then failed with "the
#  node is not answering" -- which is exactly what it should say when the
#  node is down, and the node was up the whole time.
#
#  That is a bug and bugs happen. What made it dangerous is that nothing was
#  watching: the timer stayed green because the timer fired correctly, the
#  service failed at 03:27 into a journal nobody reads, and the one thing
#  the backup exists to protect -- keys that cannot be rebuilt -- went
#  unprotected for three days while every dashboard said fine.
#
#  So this asks the only questions that matter:
#
#    * is the timer still armed
#    * did the last run actually succeed
#    * and is the newest archive newer than a day
#
#  The third is the one that cannot be fooled. A run can succeed and write
#  nothing; a timer can be perfect and the service broken. A file with a
#  recent date is evidence.
# ===========================================================================

import argparse
import os
import sys

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"
_fails = []


_warns = []


def ok(m):   print(f"  {GRN}ok{OFF}    {m}")
def bad(m):  print(f"  {RED}FAIL{OFF}  {m}"); _fails.append(m)
def warn(m): print(f"  {YEL}!!{OFF}    {m}"); _warns.append(m)


# Asking a server a question lives in one module. This file had its own copy
# and needed the same fix twice: once for the timeout path -- it announced
# "wam-backup.timer is -- nothing will run" on a machine whose backups were
# running, because one ssh call took longer than 45 seconds -- and again
# because ssh exits 255 on a connection failure rather than timing out, so a
# genuinely dead host still read as three backup failures.
#
# A false red costs as much as a false green. It is what teaches a person to
# stop reading red, and the true one then arrives among the noise.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wamssh import run as _run, UNREACHABLE   # noqa: E402


def rsh(host, cmd, timeout=45):
    rc, out = _run(host, cmd, timeout=timeout)
    return rc, out.strip()


def check(host, max_age_hours, backup_dir):
    print(f"\n{BLD}{host}{OFF}")

    rc, timer = rsh(host, "systemctl is-active wam-backup.timer")
    if rc == UNREACHABLE:
        warn(f"could not ask whether the timer is armed ({timer}). "
             f"That is not the same as it being off.")
    elif rc == 0 and timer == "active":
        ok("the timer is armed")
    else:
        bad(f"wam-backup.timer is {timer or 'unreadable'} -- nothing will run")

    # The result of the last run, not whether it is running now: this is a
    # oneshot, so it is inactive almost always and that says nothing.
    rc, result = rsh(host, "systemctl show wam-backup.service -p Result --value")
    if rc == UNREACHABLE:
        warn(f"could not ask how the last run ended ({result})")
    elif rc == 0 and result == "success":
        ok("the last run succeeded")
    elif rc == 0 and result in ("", "unknown"):
        warn("the service has not run yet on this host")
    else:
        rc2, why = rsh(
            host,
            "journalctl -u wam-backup.service -n 40 --no-pager 2>/dev/null "
            "| grep -iE 'FAIL|error' | tail -1")
        bad(f"the last run ended '{result}'" + (f" -- {why.strip()}" if why.strip() else ""))

    # The evidence. Age of the newest archive, in whole hours.
    rc, out = rsh(
        host,
        f"f=$(ls -t {backup_dir}/*.gpg 2>/dev/null | head -1); "
        f"[ -n \"$f\" ] && echo \"$(( ( $(date +%s) - $(stat -c %Y \"$f\") ) / 3600 )) "
        f"$(basename \"$f\")\" || echo NONE")

    if rc == UNREACHABLE:
        warn(f"could not look for an archive ({out}). Whether one exists is "
             f"unknown, which is not the same as none existing.")
        return
    if rc != 0 or out == "NONE" or not out:
        bad(f"no archive at all in {backup_dir} -- there is nothing to restore from")
        return

    try:
        hours = int(out.split()[0])
        name = out.split()[1]
    except (ValueError, IndexError):
        bad(f"could not read the newest archive: {out}")
        return

    if hours <= max_age_hours:
        ok(f"newest archive is {hours}h old -- {name}")
    else:
        days = hours / 24
        bad(f"the newest archive is {hours}h old ({days:.1f} days) -- {name}. "
            f"Everything since then exists in one copy, on one machine.")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("hosts", nargs="+")
    ap.add_argument("--max-age-hours", type=int, default=36,
                    help="the timer is daily, so 36h allows one missed run "
                         "without crying wolf and catches two (default: 36)")
    ap.add_argument("--dir", default="/root/backups",
                    help="where the archives are written (default: /root/backups)")
    args = ap.parse_args()

    print(f"\n{BLD}is there something to restore from{OFF}")
    for h in args.hosts:
        check(h, args.max_age_hours, args.dir)

    print()
    if _fails:
        print(f"{RED}the backup is not doing its job{OFF}\n")
        return 1
    # A host that could not be reached is not a host with good backups, and
    # the closing line must not say it is.
    if _warns:
        print(f"{YEL}no backup fault found, but {len(_warns)} question(s) "
              f"could not be put -- see the '!!' lines above{OFF}\n")
        # 2, this project's convention for "the check could not run". Not 1,
        # which says a fault was found and would put "backups FAILING" on the
        # panel over a slow ssh; and not 0, which would say every host has a
        # good archive when one of them was never asked.
        return 2
    print(f"{GRN}every host has a recent, verified archive{OFF}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

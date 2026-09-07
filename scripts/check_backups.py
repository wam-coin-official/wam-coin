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


def archive_glob(network):
    """The archives belonging to one network, and only that network.

    Mirrors deploy/wam-backup.sh, which owns this decision: every archive
    written before 2026-09-07 carries no network in its name and every one of
    them is testnet, because mainnet had never run. The testnet glob matches
    both forms so nothing on disk is orphaned; mainnet's matches only its own.
    """
    if network == "testnet":
        return f"wam-backup-testnet-*.tar.gz.gpg wam-backup-2*.tar.gz.gpg"
    return f"wam-backup-{network}-*.tar.gz.gpg"


def check_instance(host, network, timer, max_age_hours, backup_dir):
    """One network's timer, its last run, and its own newest archive."""
    service = timer.replace(".timer", ".service")

    # The result of the last run, not whether it is running now: this is a
    # oneshot, so it is inactive almost always and that says nothing.
    rc, result = rsh(host, f"systemctl show {service} -p Result --value")
    if rc == UNREACHABLE:
        warn(f"{network}: could not ask how the last run ended ({result})")
    elif rc == 0 and result == "success":
        ok(f"{network}: the last run succeeded")
    elif rc == 0 and result in ("", "unknown"):
        warn(f"{network}: the service has not run yet on this host")
    else:
        rc2, why = rsh(
            host,
            f"journalctl -u {service} -n 40 --no-pager 2>/dev/null "
            "| grep -iE 'FAIL|error' | tail -1")
        bad(f"{network}: the last run ended '{result}'"
            + (f" -- {why.strip()}" if why.strip() else ""))

    # The evidence, per network.
    #
    # This used to be `ls -t <dir>/*.gpg | head -1` -- the newest archive of
    # any network. Both networks write to the same directory, so from
    # 15 September that would have answered about testnet's fresh archive
    # while mainnet's had not been written for a week, and reported "there is
    # something to restore from" about the wallet that holds miners' money.
    # The subject of this check is exactly that wallet.
    rc, out = rsh(
        host,
        f"cd {backup_dir} 2>/dev/null || exit 9; "
        f"f=$(ls -t {archive_glob(network)} 2>/dev/null | head -1); "
        f"[ -n \"$f\" ] && echo \"$(( ( $(date +%s) - $(stat -c %Y \"$f\") ) / 3600 )) $f\" "
        f"|| echo NONE")

    if rc == UNREACHABLE:
        warn(f"{network}: could not look for an archive ({out}). Whether one "
             f"exists is unknown, which is not the same as none existing.")
        return
    if rc != 0 or out == "NONE" or not out:
        bad(f"{network}: no archive of its own in {backup_dir} -- there is "
            f"nothing to restore this network from")
        return

    try:
        hours = int(out.split()[0])
        name = out.split()[1]
    except (ValueError, IndexError):
        bad(f"{network}: could not read the newest archive: {out}")
        return

    if hours <= max_age_hours:
        ok(f"{network}: newest archive is {hours}h old -- {name}")
    else:
        days = hours / 24
        bad(f"{network}: the newest archive is {hours}h old ({days:.1f} days) "
            f"-- {name}. Everything since then exists in one copy, on one "
            f"machine.")


def check(host, max_age_hours, backup_dir):
    print(f"\n{BLD}{host}{OFF}")

    # The units are DISCOVERED, not named here.
    #
    # This asked `systemctl is-active wam-backup.timer` -- one hardcoded name.
    # On 2026-09-07 the backup became a template with one instance per network
    # and that timer was disabled, so this reported "nothing will run" about a
    # backup that had just run successfully on both hosts. A false red teaches
    # a person to stop reading red, and then the true one arrives among the
    # noise.
    #
    # Hardcoding the new name would only move the fault: enabling
    # wam-backup@mainnet.timer on 15 September has to be covered by this check
    # on the day, without anybody remembering to edit it. So the question is
    # "which backup timers does this machine have", and the answer decides
    # what is examined.
    rc, out = rsh(
        host,
        "systemctl list-units --type=timer --all --no-legend 'wam-backup*' "
        "2>/dev/null | awk '{print $1, $3}'")
    if rc == UNREACHABLE:
        warn(f"could not ask which backup timers exist ({out}). That is not "
             f"the same as there being none.")
        return

    timers = {}
    for line in (out or "").splitlines():
        parts = line.split()
        if len(parts) < 2 or not parts[0].endswith(".timer"):
            continue
        # The template itself is not an instance and cannot be active.
        if parts[0] == "wam-backup@.timer":
            continue
        timers[parts[0]] = parts[1]

    active = {t: s for t, s in timers.items() if s == "active"}

    if not active:
        bad(f"no backup timer is active on this host -- nothing will run "
            f"(found: {', '.join(f'{t}={s}' for t, s in timers.items()) or 'none at all'})")
        return

    for timer in sorted(active):
        network = "testnet"
        if "@" in timer:
            network = timer.split("@", 1)[1].rsplit(".timer", 1)[0]
        ok(f"{network}: the timer is armed ({timer})")
        check_instance(host, network, timer, max_age_hours, backup_dir)

    # Both the old single unit and a template instance being armed would take
    # two backups a night of the same data under two different names, and the
    # rotation counts them together. Worth saying out loud rather than
    # discovering it as a disk filling up.
    if "wam-backup.timer" in active and any("@" in t for t in active):
        warn("the pre-template wam-backup.timer is armed as well as an "
             "instance -- both will run tonight")


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

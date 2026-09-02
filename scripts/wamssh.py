#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  wamssh.py -- one way to ask a server a question
# ===========================================================================
#
#      from wamssh import run, UNREACHABLE
#
#      rc, out = run("169.58.159.165", "wam-cli -testnet getblockcount")
#      if rc == UNREACHABLE:
#          warn("could not ask: " + out)      # NOT a finding
#
#  WHY ONE PLACE
#
#  Three scripts had their own copy of this, and each learned the same lesson
#  separately and late:
#
#    check_backups.py       reported "wam-backup.timer is -- nothing will run"
#                           when a single ssh call took longer than 45 seconds.
#                           Fixed. Then it turned out ssh exits 255 on a
#                           connection failure rather than timing out, so a
#                           genuinely dead host still read as three backup
#                           failures. Fixed again.
#
#    check_peer_versions.py let subprocess.TimeoutExpired escape entirely and
#                           died with a Python traceback, whose exit code the
#                           ops panel printed as "everyone can follow mainnet:
#                           FAILING" -- which says somebody on the network will
#                           be rejected on launch day. Nothing had been
#                           measured. Then it needed the 255 fix too.
#
#    ops.py                 passed the script as an argument, which Windows
#                           rewrote, and later as text, which Windows filled
#                           with carriage returns.
#
#  Four fixes for one behaviour, in three files, over one day. That is what a
#  copy costs.
#
#  THE RULE THIS ENCODES
#
#  "I could not ask" and "the answer is no" are different, and a monitor that
#  confuses them is worse than no monitor: a false red teaches a person to
#  stop reading red, and the true one then arrives inside noise nobody looks
#  at. Callers get UNREACHABLE and are expected to warn, not to fail.
#
#  Exit 2 is this project's convention for "the check could not run", and the
#  sweep and the ops panel both understand it.
# ===========================================================================

import subprocess
import time

# Distinct from any exit status a remote command can return.
UNREACHABLE = -1

# ssh reserves 255 for its own failures and never uses it for a status it
# received from the far end. A host that is down is otherwise indistinguishable
# from one that answered "no".
SSH_OWN_ERROR = 255

TRIES = 2
GAP_SECONDS = 3


def run(host, cmd, timeout=45, tries=TRIES):
    """Ask one host one question. Never raises.

    Returns (rc, text). rc is UNREACHABLE if the question could not be put at
    all; otherwise it is the remote command's own exit status.

    The command goes in on stdin as BYTES, never as an argument:

      * as an argument it is one element of argv, and the kernel refuses any
        single argument over 128 KiB -- which check_reorg.py walked into as
        the chain grew;
      * on Windows there is no argv at all, so Python rebuilds a command line
        and escapes what is in it;
      * and in text mode Windows rewrites every newline as CRLF, which the
        remote bash reads as `$'\\r'` and dies on.

    Bytes on stdin has none of those properties on any platform.
    """
    last = ""
    for attempt in range(max(1, tries)):
        try:
            p = subprocess.run(
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                 "-o", "StrictHostKeyChecking=accept-new",
                 f"root@{host}", "bash -s"],
                input=cmd.encode("utf-8"), capture_output=True,
                timeout=timeout)
            if p.returncode == SSH_OWN_ERROR:
                err = p.stderr.decode("utf-8", "replace").strip().splitlines()
                last = (err or ["connection failed"])[-1][:140]
            else:
                return p.returncode, p.stdout.decode("utf-8", "replace")
        except subprocess.TimeoutExpired:
            last = f"no answer within {timeout}s"
        except Exception as e:
            last = f"{type(e).__name__}: {e}"
        if attempt + 1 < tries:
            time.sleep(GAP_SECONDS)
    return UNREACHABLE, last

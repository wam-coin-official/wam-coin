#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  wamnotify.py -- the one place that knows how to reach a person
# ===========================================================================
#
#  Import it:
#
#      from wamnotify import send
#      send("the pool stopped paying")
#
#  WHY IT IS ONE PLACE
#
#  Delivery has two rules that are easy to get wrong twice. First, a host
#  without a bot token must not be given one -- whoever took that machine
#  could otherwise post to the public announcement channel in the founder's
#  name -- so its alarms are parked in a file that the host holding the token
#  reads and forwards. Second, the parked file must be capped, because the
#  forwarding host dedupes by hash and cannot write an acknowledgement back
#  through a key that runs one read-only command.
#
#  Both rules were written into the login watcher first. The second thing
#  that needed to raise an alarm would have copied them, and a copy is where
#  the two versions start to differ.
# ===========================================================================

import json
import os
import urllib.parse
import urllib.request

CONF = "/etc/wam/announce.json"
PENDING = "/var/lib/wam-login-watch/pending.txt"

# Two hundred lines is far more than the few minutes between forwarding runs,
# and small enough that reading the file costs nothing.
KEEP = 200


def park(text):
    """No way to send from here. Leave it where the other machine looks."""
    try:
        os.makedirs(os.path.dirname(PENDING), exist_ok=True)
        with open(PENDING, "a") as f:
            f.write(text.replace("\n", " ") + "\n")
        with open(PENDING) as f:
            lines = f.readlines()
        if len(lines) > KEEP:
            with open(PENDING, "w") as f:
                f.writelines(lines[-KEEP:])
    except OSError:
        pass
    print(text)


def send(text, dry=False):
    """Deliver, or park it for the host that can."""
    if dry:
        print(text)
        return
    # A host with no announce.json is a host that was never given a token,
    # which is the design and not a fault. Parking it quietly is right; the
    # first version let the missing file fall through to the error path and
    # stamped every alarm Singapore raised with "FileNotFoundError", which
    # reads as a broken alerter rather than a working one.
    try:
        cfg = json.load(open(CONF))
        chat = cfg.get("opsChatId")
        token = cfg.get("telegram", {}).get("token")
    except (OSError, ValueError):
        park(text)
        return
    if not (chat and token):
        park(text)
        return
    try:
        data = urllib.parse.urlencode({
            "chat_id": chat, "text": text,
            "disable_web_page_preview": "true"}).encode()
        with urllib.request.urlopen(urllib.request.Request(
                f"https://api.telegram.org/bot{token}/sendMessage", data=data),
                timeout=25) as r:
            # A 200 with {"ok": false} is Telegram accepting the request and
            # refusing the message -- a wrong chat id reads exactly like a
            # delivered alarm if the body is not read.
            body = json.loads(r.read().decode())
        if not body.get("ok"):
            park(f"{text}  [telegram refused it: "
                 f"{str(body.get('description'))[:80]}]")
    except Exception as e:
        park(f"{text}  [could not send from that host: {type(e).__name__}]")


if __name__ == "__main__":
    # So a person can prove delivery whenever they want to, rather than
    # trusting that the last alarm would have arrived:
    #
    #     python3 scripts/wamnotify.py "test from France"
    import sys
    send(" ".join(sys.argv[1:]) or "wamnotify test")
    print("sent, or parked if this host holds no token")

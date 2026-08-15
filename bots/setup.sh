#!/bin/bash
# ===========================================================================
#  setup.sh -- configure the WAM announcement bot for Telegram and/or Discord
# ===========================================================================
#
#      sudo bash bots/setup.sh
#
#  ABOUT THE CREDENTIALS
#  ---------------------
#  You paste them here, once, on your own machine. They are read with the
#  terminal echo off, so they do not appear on screen, do not reach
#  ~/.bash_history, and are never a command-line argument -- an argument is
#  visible in `ps` to every other process on the box.
#
#  They are written to a file only this bot's user can read, outside the
#  repository. Never put them in the repository: a secret inside a git working
#  tree is one `git add -A` away from being public, and no amount of care
#  prevents that reliably.
#
#  Nobody else ever needs to see them. Not a collaborator, not a support
#  channel, not an assistant helping you build this. A credential that only you
#  have seen cannot leak from anywhere else.
#
#  WHY DISCORD USES A WEBHOOK AND NOT THE BOT TOKEN
#  ------------------------------------------------
#  A webhook posts to exactly one channel. It cannot read a message, list your
#  members, remove anybody, or touch another channel. A bot token can do all of
#  those. Announcements need none of them, so the worst a leaked webhook can do
#  is post nonsense in one channel -- embarrassing, and undone in a minute by
#  deleting the webhook. A leaked bot token is the server.
#
#  Keep the bot you created for later, if you want slash commands. This is not
#  it and does not need it.
# ===========================================================================

set -euo pipefail

BOT_USER="wam-announce"
CONF_DIR="/etc/wam"
CONF="$CONF_DIR/announce.json"
INSTALL_DIR="/opt/wam"
UNIT="wam-announce.service"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; OFF=$'\033[0m'
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '  %swarn%s  %s\n' "$YLW" "$OFF" "$*"; }
fail() { printf '  %sfail%s  %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
step() { printf '\n%s%s%s\n' "$CYN" "$*" "$OFF"; }

[ "$(id -u)" = "0" ] || fail "run this with sudo -- it creates a system user and a unit file"

command -v node >/dev/null || fail "node is not installed"
command -v curl >/dev/null || fail "curl is not installed"
command -v python3 >/dev/null || fail "python3 is not installed (used to write JSON safely)"

# ---------------------------------------------------------------------------
step "1. the user this runs as"

if id -u "$BOT_USER" >/dev/null 2>&1; then
    ok "$BOT_USER exists"
else
    # No shell, no home, no login. If something ever does get code execution
    # inside this process, it lands as a user that owns nothing.
    useradd --system --no-create-home --shell /usr/sbin/nologin "$BOT_USER"
    ok "created $BOT_USER (system account, no shell, no home)"
fi

# ---------------------------------------------------------------------------
step "2. where the credentials will live"

mkdir -p "$CONF_DIR"
chmod 750 "$CONF_DIR"
chgrp "$BOT_USER" "$CONF_DIR"
ok "$CONF_DIR  (0750, group $BOT_USER)"

if [ -f "$CONF" ]; then
    warn "$CONF already exists"
    printf '        Overwrite it? Existing credentials will be replaced. [y/N] '
    read -r REPLY </dev/tty
    case "$REPLY" in [yY]*) ;; *) fail "left the existing config alone" ;; esac
fi

# Created empty and locked down *before* anything is written into it, so the
# secrets are never briefly readable while the file is being assembled.
umask 077
: > "$CONF"
chmod 600 "$CONF"
chown "$BOT_USER:$BOT_USER" "$CONF"

# ---------------------------------------------------------------------------
step "3. Telegram"

TG_TOKEN=""; TG_CHAT=""

# If a Telegram bot is already posting on this machine, its credentials are on
# disk and are *proven* -- they have been delivering messages. Asking anyone to
# retype a ten-digit id and a forty-character token is asking for a typo, and
# the typo does not announce itself: it fails as "could not post -- is the bot
# an admin?", which sends you to check permissions that were never wrong.
#
# That is exactly what happened here. Nothing is shown on screen and nothing
# passes through a shell; the values are read from the file into the process.
OLD_TG=""
for f in /root/.wam/telegram-config.json /etc/wam/telegram-config.json; do
    [ -f "$f" ] || continue
    if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("telegram",{}).get("token") else 1)' "$f" 2>/dev/null; then
        OLD_TG="$f"; break
    fi
done

printf '  Add a Telegram channel? [Y/n] '
read -r REPLY </dev/tty
case "${REPLY:-y}" in
[nN]*) warn "skipping Telegram" ;;
*)
    if [ -n "$OLD_TG" ]; then
        printf '\n  A Telegram bot is already configured on this machine:\n'
        printf '      %s\n' "$OLD_TG"
        printf '  Reuse its credentials? Nothing is displayed and nothing is retyped. [Y/n] '
        read -r REPLY </dev/tty
        case "${REPLY:-y}" in
        [nN]*) : ;;
        *)
            TG_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["telegram"]["token"])' "$OLD_TG")
            TG_CHAT=$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["telegram"]; print(t.get("chatId") or t.get("chat_id") or "")' "$OLD_TG")

            # Imported, but still verified. A config file can be stale, and a
            # credential nobody has tested is a credential nobody should trust.
            NAME=$(curl -sS -m 20 "https://api.telegram.org/bot${TG_TOKEN}/getMe" \
                   | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"]["username"] if d.get("ok") else "")' 2>/dev/null || true)

            if [ -n "$NAME" ]; then
                ok "imported and verified: @$NAME -> $TG_CHAT"
            else
                # A revoked token is not a reason to throw the chat id away.
                # They fail independently: the token is replaced at BotFather,
                # while the chat id never changes and cannot be revoked -- and
                # it is the value that gets mistyped, because it is the one
                # people retype rather than paste.
                TG_TOKEN=""
                warn "the stored token is no longer valid -- revoked, most likely"
                if [ -n "$TG_CHAT" ]; then
                    ok "keeping the channel id from $OLD_TG: $TG_CHAT"
                    printf '        Only the new token is needed below.\n'
                fi
            fi
            ;;
        esac
    fi

    if [ -z "$TG_TOKEN" ]; then
    printf '\n  Paste the bot token from @BotFather.\n'
    printf '  It will not be shown as you type, and will not be saved to your shell history.\n'
    printf '  Token: '
    read -r -s TG_TOKEN </dev/tty
    printf '\n'
    [ -n "$TG_TOKEN" ] || fail "no token given"

    printf '%s' "$TG_TOKEN" | grep -qE '^[0-9]{6,}:[A-Za-z0-9_-]{30,}$' \
        || fail "that does not look like a Telegram bot token (expected 123456:ABC-DEF...)"

    # Verified against Telegram before it is written. A token that is wrong is
    # far cheaper to discover now than as a silent channel in three weeks.
    NAME=$(curl -sS -m 20 "https://api.telegram.org/bot${TG_TOKEN}/getMe" \
           | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"]["username"] if d.get("ok") else "")' 2>/dev/null || true)
    [ -n "$NAME" ] || fail "Telegram rejected that token"
    ok "Telegram accepted the token: @$NAME"
    fi   # the token

    # Asked for separately from the token, because they fail separately. A
    # revoked token needs replacing; the channel it posts to did not change,
    # and re-entering an id that was already correct is how a digit gets lost.
    if [ -n "$TG_CHAT" ]; then
        printf '\n  Channel id [%s]: ' "$TG_CHAT"
        read -r REPLY </dev/tty
        [ -n "$REPLY" ] && TG_CHAT="$REPLY"
    else
        printf '\n  Channel or chat id (e.g. -1001234567890).\n'
        printf '  Add the bot to the channel as an administrator first.\n'
        printf '  Chat id: '
        read -r TG_CHAT </dev/tty
        [ -n "$TG_CHAT" ] || fail "no chat id given"
    fi

    # The test post happens for imported credentials too. An import that is
    # never exercised proves only that a file exists.
    TG_ERR=$(curl -sS -m 20 -X POST \
        -H 'Content-Type: application/json' \
        -d "$(python3 -c 'import json,sys; print(json.dumps({"chat_id": sys.argv[1], "text": "WAM announcement bot connected."}))' "$TG_CHAT")" \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print("" if d.get("ok") else d.get("description", "unknown error"))
except Exception:
    print("no reply from Telegram")' 2>/dev/null || true)

    if [ -n "$TG_ERR" ]; then
        # Telegram says which of the two it is, so say that rather than
        # guessing. "chat not found" is a wrong id -- one mistyped digit -- and
        # sends people to check admin rights that were never the problem.
        printf '  %sfail%s  Telegram refused: %s\n' "$RED" "$OFF" "$TG_ERR" >&2
        case "$TG_ERR" in
        *"chat not found"*)
            printf '        That chat id does not exist. It is not a permissions\n' >&2
            printf '        problem -- check the digits, and that it starts with -100.\n' >&2 ;;
        *"not enough rights"*|*"kicked"*|*"not a member"*|*"CHAT_ADMIN"*)
            printf '        The id is real but this bot cannot post there. Add it to\n' >&2
            printf '        the channel as an administrator and run this again.\n' >&2 ;;
        esac
        exit 1
    fi
    ok "posted a test message to $TG_CHAT"
    ;;
esac

# ---------------------------------------------------------------------------
step "4. Discord"

DC_HOOK=""
printf '  Add a Discord channel? [Y/n] '
read -r REPLY </dev/tty
case "${REPLY:-y}" in
[nN]*) warn "skipping Discord" ;;
*)
    printf '\n  In Discord: Server Settings -> Integrations -> Webhooks -> New Webhook.\n'
    printf '  Choose the channel, then Copy Webhook URL.\n'
    printf '\n  %sUse a webhook, not your bot token.%s A webhook can only post to that\n' "$CYN" "$OFF"
    printf '  one channel; it cannot read messages or manage your server.\n'
    printf '\n  Webhook URL: '
    read -r -s DC_HOOK </dev/tty
    printf '\n'
    [ -n "$DC_HOOK" ] || fail "no webhook given"

    printf '%s' "$DC_HOOK" | grep -qE '^https://(canary\.|ptb\.)?discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$' \
        || fail "that is not a Discord webhook URL"

    CODE=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -d '{"content":"WAM announcement bot connected.","allowed_mentions":{"parse":[]}}' \
        "$DC_HOOK" || true)
    case "$CODE" in
    20*|204) ok "posted a test message to the Discord channel" ;;
    401|403) fail "Discord rejected that webhook (HTTP $CODE) -- was it deleted?" ;;
    404)     fail "Discord does not know that webhook (HTTP 404) -- check the URL" ;;
    *)       fail "Discord returned HTTP $CODE" ;;
    esac
    ;;
esac

[ -n "$TG_TOKEN" ] || [ -n "$DC_HOOK" ] || fail "no channel configured; nothing to do"

# ---------------------------------------------------------------------------
step "5. the node"

RPC_USER=""; RPC_PASS=""; RPC_PORT="${RPC_PORT:-}"; WAM_CONF=""
for f in /etc/wam/wam.conf /opt/wam/wam.conf "$HOME/.wam/wam.conf"; do
    [ -f "$f" ] || continue
    RPC_USER=$(grep -m1 '^rpcuser=' "$f" 2>/dev/null | cut -d= -f2- || true)
    RPC_PASS=$(grep -m1 '^rpcpassword=' "$f" 2>/dev/null | cut -d= -f2- || true)
    [ -n "$RPC_USER" ] && { WAM_CONF="$f"; ok "read RPC credentials from $f"; break; }
done

if [ -z "$RPC_USER" ]; then
    printf '  RPC username: '; read -r RPC_USER </dev/tty
    printf '  RPC password: '; read -r -s RPC_PASS </dev/tty; printf '\n'
fi

# The port is derived, never assumed. WAM's RPC ports are the peer port minus
# one -- Bitcoin Core reserves peer+1 for its Tor listener -- so guessing "the
# peer port" points the bot at the wrong socket, and it fails with a connection
# error that looks like a dead node rather than a wrong number.
if [ -z "$RPC_PORT" ] && [ -n "$WAM_CONF" ]; then
    RPC_PORT=$(grep -m1 '^rpcport=' "$WAM_CONF" 2>/dev/null | cut -d= -f2- || true)
    [ -n "$RPC_PORT" ] && ok "rpcport is declared in $WAM_CONF: $RPC_PORT"
fi

if [ -z "$RPC_PORT" ] && [ -n "$WAM_CONF" ]; then
    # Not declared, so it is the built-in default for whichever network the
    # node is on. These are WAM's own numbers, not Bitcoin's.
    if   grep -qE '^regtest=1'  "$WAM_CONF"; then RPC_PORT=29554
    elif grep -qE '^signet=1'   "$WAM_CONF"; then RPC_PORT=39554
    elif grep -qE '^testnet4=1' "$WAM_CONF"; then RPC_PORT=49554
    elif grep -qE '^testnet=1'  "$WAM_CONF"; then RPC_PORT=19554
    else                                          RPC_PORT=9554
    fi
    ok "rpcport is not declared; the default for this network is $RPC_PORT"
fi

printf '  RPC port [%s]: ' "${RPC_PORT:-9554}"; read -r REPLY </dev/tty
[ -n "$REPLY" ] && RPC_PORT="$REPLY"
RPC_PORT="${RPC_PORT:-9554}"

# Proven, not assumed. One call now, against the real node, so a wrong port or
# a wrong password is a message here rather than a bot that starts cleanly and
# announces nothing.
CHAIN=$(curl -sS -m 15 --user "$RPC_USER:$RPC_PASS" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}' \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    r = d.get("result") or {}
    print("%s %s" % (r.get("chain",""), r.get("blocks","")))
except Exception:
    print("")' 2>/dev/null || true)

case "$CHAIN" in
    ""|" ") fail "no answer from the node on 127.0.0.1:$RPC_PORT -- wrong port, or wrong rpcuser/rpcpassword" ;;
    *)      ok "node answered on $RPC_PORT: chain ${CHAIN% *}, height ${CHAIN#* }" ;;
esac

# ---------------------------------------------------------------------------
step "6. writing the config"

# Written by python rather than by shell interpolation: a password containing a
# quote or a backslash would otherwise produce a JSON file that either fails to
# parse or, worse, parses into something subtly different.
TG_TOKEN="$TG_TOKEN" TG_CHAT="$TG_CHAT" DC_HOOK="$DC_HOOK" \
RPC_USER="$RPC_USER" RPC_PASS="$RPC_PASS" RPC_PORT="$RPC_PORT" \
python3 - "$CONF" <<'PY'
import json, os, sys

cfg = {
    "node": {
        "host": "127.0.0.1",
        "port": int(os.environ["RPC_PORT"]),
        "user": os.environ["RPC_USER"],
        "password": os.environ["RPC_PASS"],
    },
    "pollSeconds": 60,
    "heartbeatHours": 24,
    "stallMinutes": 60,
    "githubRepo": "wam-coin-official/wam-coin",
    "explorerUrl": "https://explorer.wamcoin.org",
    "stateFile": "/var/lib/wam-announce/state.json",
}
if os.environ.get("TG_TOKEN"):
    cfg["telegram"] = {"token": os.environ["TG_TOKEN"], "chatId": os.environ["TG_CHAT"]}
if os.environ.get("DC_HOOK"):
    cfg["discord"] = {"webhookUrl": os.environ["DC_HOOK"], "username": "WAM Network"}

with open(sys.argv[1], "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
PY

chmod 600 "$CONF"
chown "$BOT_USER:$BOT_USER" "$CONF"
ok "$CONF  (0600, owned by $BOT_USER)"

# The one check that matters: nobody else can read it.
PERMS=$(stat -c '%a' "$CONF")
[ "$PERMS" = "600" ] || fail "$CONF ended up mode $PERMS"

# ---------------------------------------------------------------------------
step "7. the service"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$REPO_ROOT" != "$INSTALL_DIR" ]; then
    warn "the unit runs $INSTALL_DIR/bots/announce.js; this checkout is $REPO_ROOT"
    warn "deploy the code to $INSTALL_DIR, or edit the unit before starting it"
fi

install -m 644 "$REPO_ROOT/deploy/systemd/$UNIT" "/etc/systemd/system/$UNIT"
systemctl daemon-reload
ok "installed /etc/systemd/system/$UNIT"

printf '\n  A dry run first, so you see the messages before anyone else does:\n\n'
printf '      sudo -u %s WAM_ANNOUNCE_CONFIG=%s node %s/bots/announce.js --once --dry-run\n\n' \
    "$BOT_USER" "$CONF" "$INSTALL_DIR"
printf '  Then start it:\n\n'
printf '      sudo systemctl enable --now %s\n\n' "$UNIT"
printf '  %sThe credentials are in %s and nowhere else.%s\n' "$GRN" "$CONF" "$OFF"
printf '  Nobody needs a copy of them -- not a collaborator, not a support\n'
printf '  channel, not an assistant. If one ever leaks, revoke it at the source\n'
printf '  (@BotFather for Telegram, Delete Webhook for Discord) and run this again.\n\n'

#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  setup.sh -- put the bot token into config.json without it being seen
# ===========================================================================
#
#      bash telegram/setup.sh
#
#  A bot token is a password for a channel. Typing it into an editor leaves it
#  on screen; passing it on a command line leaves it in ~/.bash_history and in
#  the process list, where any other process on the machine can read it. This
#  reads it the way a password should be read: hidden, straight into the file,
#  never echoed and never in an argument.
#
#  It also asks Telegram whether the token works before writing anything, so a
#  mistyped character is caught here rather than by silence six hours later.
# ===========================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-$HERE/config.json}"
EXAMPLE="$HERE/config.example.json"

fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }

command -v jq   >/dev/null 2>&1 || fail "jq is not installed:  sudo apt-get install -y jq"
command -v curl >/dev/null 2>&1 || fail "curl is not installed"

echo "=================================================================="
echo " WAM announcement bot -- credentials"
echo "=================================================================="
echo
echo "  Nothing you type below is echoed to the screen, saved to your shell"
echo "  history, or passed as a command-line argument."
echo

[ -f "$CONFIG" ] || cp "$EXAMPLE" "$CONFIG"
chmod 600 "$CONFIG"

# ---------------------------------------------------------------------------
printf 'Bot token from @BotFather: '
read -r -s TOKEN
echo

[ -n "$TOKEN" ] || fail "no token given"

# 8123456789:AA...  -- catching the shape here turns a silent failure into a
# sentence.
if ! printf '%s' "$TOKEN" | grep -qE '^[0-9]{6,}:[A-Za-z0-9_-]{30,}$'; then
    fail "that does not look like a bot token. BotFather's tokens are a number,
     a colon, then about thirty-five letters and digits. Copy the whole line."
fi

echo
echo "  checking it with Telegram..."
ME=$(curl -sS -m 20 "https://api.telegram.org/bot${TOKEN}/getMe") \
    || fail "could not reach api.telegram.org"

if [ "$(printf '%s' "$ME" | jq -r '.ok')" != "true" ]; then
    fail "Telegram rejected the token: $(printf '%s' "$ME" | jq -r '.description')"
fi
BOT_NAME=$(printf '%s' "$ME" | jq -r '.result.username')
ok "token belongs to @${BOT_NAME}"

# ---------------------------------------------------------------------------
echo
echo "  The channel id. For a public channel this is @name."
echo "  For a private one it is a negative number -- post any message there,"
echo "  open https://api.telegram.org/bot<TOKEN>/getUpdates and read"
echo '  "chat":{"id":-100...}'
echo
printf 'Channel id: '
read -r CHAT
[ -n "$CHAT" ] || fail "no channel id given"

echo
echo "  sending a test message..."
RESPONSE=$(curl -sS -m 20 -X POST \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg c "$CHAT" \
          '{chat_id:$c, text:"WAM announcement bot connected.", disable_notification:true}')" \
    "https://api.telegram.org/bot${TOKEN}/sendMessage") \
    || fail "could not reach api.telegram.org"

if [ "$(printf '%s' "$RESPONSE" | jq -r '.ok')" != "true" ]; then
    DESC=$(printf '%s' "$RESPONSE" | jq -r '.description')
    case "$DESC" in
        *"chat not found"*)
            fail "Telegram cannot see that channel. Check the id, and make sure
     @${BOT_NAME} has been added to the channel as an administrator." ;;
        *"not enough rights"*|*"CHAT_ADMIN_REQUIRED"*)
            fail "@${BOT_NAME} is in the channel but cannot post. Give it the
     'Post Messages' permission in the channel's administrator settings." ;;
        *) fail "Telegram refused: $DESC" ;;
    esac
fi
ok "test message delivered -- look at the channel"

# ---------------------------------------------------------------------------
# jq writes the file, so no amount of odd characters in the token can corrupt
# the JSON. The temporary file is created with restrictive permissions before
# the token ever reaches it.
TMP=$(mktemp "${CONFIG}.XXXXXX")
chmod 600 "$TMP"
jq --arg t "$TOKEN" --arg c "$CHAT" \
   '.telegram.token = $t | .telegram.chatId = $c' \
   "$CONFIG" > "$TMP"
mv "$TMP" "$CONFIG"
chmod 600 "$CONFIG"

unset TOKEN

echo
ok "written to $CONFIG (readable only by you)"
echo
echo "=================================================================="
echo " Try it without sending anything:"
echo
echo "   node $HERE/bot.js --once --dry-run"
echo
echo " config.json is in .gitignore. It must never be committed."
echo "=================================================================="

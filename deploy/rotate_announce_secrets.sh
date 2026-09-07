#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  rotate_announce_secrets.sh -- replace the announcer's credentials safely
# ===========================================================================
#
#      ssh root@<host> 'bash /opt/wam/deploy/rotate_announce_secrets.sh'
#
#  WHY THIS EXISTS
#
#  On 7 September 2026 I printed the live Telegram bot token and the live
#  Discord webhook URL into a conversation, while trying to redact them: the
#  sed I wrote appended the word "redacted" after each value instead of
#  replacing it. Both are bearer credentials -- whoever holds the webhook can
#  post as "WAM Network" -- so both had to be rotated.
#
#  Rotating them by hand means editing a JSON file with the new secrets on
#  screen, and one missing comma stops the announcer. This does the same job
#  without either problem:
#
#    * the values are typed into a prompt on the host, never into a command
#      line, a chat, a file the operator has to open, or shell history
#    * each one is CHECKED against its own service before anything is
#      written -- Telegram's getMe and a GET on the webhook, neither of which
#      posts anything -- so a bad paste is refused rather than installed
#    * the old config is kept, and restored if any step fails
#    * nothing is ever echoed. The only output is ok/failed and the bot's
#      public username.
#
#  WHAT IT CANNOT DO
#
#  Issue the credentials. Revoking a Telegram token happens in BotFather from
#  the owner's account, and creating a webhook happens in Discord's channel
#  settings. Those are the operator's to do; this takes it from there.
# ===========================================================================

set -uo pipefail
umask 077

CFG="${ANNOUNCE_CONFIG:-/etc/wam/announce.json}"
UNIT="${ANNOUNCE_UNIT:-wam-announce}"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$*"; }
warn() { printf '  %s!!%s    %s\n' "$YLW" "$OFF" "$*"; }
die()  { printf '\n  %sSTOPPED%s  %s\n\n' "$RED" "$OFF" "$*" >&2; exit 1; }

[ -f "$CFG" ] || die "no config at $CFG"
command -v jq >/dev/null    || die "jq is not installed"
command -v curl >/dev/null  || die "curl is not installed"
[ -t 0 ] || die "this must be run interactively -- it prompts for the secrets.
           Use:  ssh -t root@<host> 'bash /opt/wam/deploy/rotate_announce_secrets.sh'"

echo
echo "=================================================================="
echo " ${BLD}rotate the announcer's credentials${OFF}"
echo "=================================================================="
echo
echo "  Paste each value at the prompt. Nothing is echoed, nothing is"
echo "  written until it has been checked, and neither service is posted to."
echo

BACKUP="$CFG.$(date -u +%Y%m%d-%H%M%S).bak"
cp -p "$CFG" "$BACKUP" || die "could not back up $CFG"
chmod 600 "$BACKUP"
ok "current config kept at $BACKUP"

restore() {
    cp -p "$BACKUP" "$CFG" 2>/dev/null && warn "config restored from the backup"
}

# ---------------------------------------------------------------------------
#  Telegram
# ---------------------------------------------------------------------------
printf '\n%sTelegram bot token%s  (from BotFather /revoke, or blank to keep the current one)\n' \
    "$BLD" "$OFF"
printf '  token: '
IFS= read -rs TG_TOKEN
echo

if [ -n "$TG_TOKEN" ]; then
    # getMe reads; it does not send a message to anybody.
    TG_JSON="$(curl -s --max-time 20 "https://api.telegram.org/bot$TG_TOKEN/getMe" || true)"
    TG_OK="$(printf '%s' "$TG_JSON" | jq -r '.ok // false' 2>/dev/null || echo false)"
    if [ "$TG_OK" != "true" ]; then
        DESC="$(printf '%s' "$TG_JSON" | jq -r '.description // "no answer from Telegram"' 2>/dev/null)"
        die "Telegram refused that token: $DESC
           Nothing was written. The old token is still in place -- though if
           you have already run /revoke it is dead, so get the new one from
           BotFather and run this again."
    fi
    TG_USER="$(printf '%s' "$TG_JSON" | jq -r '.result.username // "?"')"
    ok "Telegram accepts it -- the bot is @$TG_USER"
else
    warn "Telegram token left as it is"
fi

# ---------------------------------------------------------------------------
#  Discord
# ---------------------------------------------------------------------------
printf '\n%sDiscord webhook URL%s  (Channel -> Integrations -> Webhooks, or blank to keep)\n' \
    "$BLD" "$OFF"
printf '  url: '
IFS= read -rs DC_URL
echo

if [ -n "$DC_URL" ]; then
    case "$DC_URL" in
        https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) ;;
        *) die "that does not look like a Discord webhook URL. Nothing was written." ;;
    esac
    # A GET on a webhook returns its own description. It posts nothing.
    DC_CODE="$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' "$DC_URL" || echo 000)"
    if [ "$DC_CODE" != "200" ]; then
        die "Discord answered HTTP $DC_CODE for that webhook -- 401 or 404 means
           it is wrong or already deleted. Nothing was written."
    fi
    ok "Discord accepts it (HTTP 200)"
else
    warn "Discord webhook left as it is"
fi

if [ -z "$TG_TOKEN" ] && [ -z "$DC_URL" ]; then
    echo
    warn "nothing to change -- both were left blank"
    rm -f "$BACKUP"
    echo
    exit 0
fi

# ---------------------------------------------------------------------------
#  Write, atomically, keeping owner and mode
# ---------------------------------------------------------------------------
printf '\n%swriting%s\n' "$BLD" "$OFF"

TMP="$(mktemp "${CFG}.XXXXXX")" || die "could not create a temporary file beside $CFG"
chmod 600 "$TMP"
trap 'rm -f "$TMP"' EXIT

# --arg, so a value containing anything at all cannot break the JSON.
jq --arg tg "$TG_TOKEN" --arg dc "$DC_URL" '
    (if $tg == "" then . else .telegram.token = $tg end)
  | (if $dc == "" then . else .discord.webhookUrl = $dc end)
' "$CFG" > "$TMP" || { restore; die "jq could not rewrite the config"; }

jq . "$TMP" >/dev/null 2>&1 || { restore; die "the rewritten config is not valid JSON"; }

# The service reads this as its own user; keep whatever ownership it had.
OWNER="$(stat -c '%U:%G' "$CFG")"
chown "$OWNER" "$TMP" 2>/dev/null || true
mv -f "$TMP" "$CFG" || { restore; die "could not move the new config into place"; }
trap - EXIT
ok "config rewritten, owner $OWNER, mode 600"

# ---------------------------------------------------------------------------
printf '\n%srestarting %s%s\n' "$BLD" "$UNIT" "$OFF"

systemctl restart "$UNIT" || { restore; systemctl restart "$UNIT" 2>/dev/null; \
    die "$UNIT would not restart. The old config has been put back."; }
sleep 3
STATE="$(systemctl is-active "$UNIT" 2>/dev/null || true)"
if [ "$STATE" != "active" ]; then
    journalctl -u "$UNIT" -n 12 --no-pager 2>/dev/null | sed 's/^/          /'
    restore
    systemctl restart "$UNIT" 2>/dev/null
    die "$UNIT is '$STATE' after the change. The old config has been put back."
fi
ok "$UNIT is active"

# ---------------------------------------------------------------------------
#  Read the values back out of the file and prove them again, so what is
#  confirmed is what the service will actually use -- not what was typed.
# ---------------------------------------------------------------------------
printf '\n%sconfirming what the service now holds%s\n' "$BLD" "$OFF"

TG_CHECK="$(jq -r '"https://api.telegram.org/bot" + .telegram.token + "/getMe"' "$CFG" \
    | xargs -r curl -s --max-time 20 | jq -r '.result.username // "FAILED"' 2>/dev/null || echo FAILED)"
[ "$TG_CHECK" != "FAILED" ] && ok "Telegram: @$TG_CHECK" || bad "Telegram: the stored token does not work"

DC_CHECK="$(jq -r '.discord.webhookUrl' "$CFG" \
    | xargs -r curl -s --max-time 20 -o /dev/null -w '%{http_code}' || echo 000)"
[ "$DC_CHECK" = "200" ] && ok "Discord: HTTP 200" || bad "Discord: HTTP $DC_CHECK"

echo
echo "=================================================================="
if [ "$TG_CHECK" != "FAILED" ] && [ "$DC_CHECK" = "200" ]; then
    printf ' %s%sboth credentials rotated and working -- nothing was posted%s\n' "$GRN" "$BLD" "$OFF"
    echo "=================================================================="
    echo
    echo "  The old config is still at:"
    echo "      $BACKUP"
    echo "  It holds the REVOKED secrets. Delete it once you are satisfied:"
    echo "      rm -f $BACKUP"
    echo
    exit 0
fi
printf ' %sthe service is running but one credential does not answer%s\n' "$RED" "$OFF"
echo "=================================================================="
echo
echo "  The previous config is at $BACKUP if you want it back."
echo
exit 1

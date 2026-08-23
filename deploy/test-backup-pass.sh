#!/usr/bin/env bash
# ===========================================================================
#  test-backup-pass.sh -- prove the passphrase you wrote down is the right one
# ===========================================================================
#
#      bash /usr/local/bin/test-backup-pass.sh
#
#  Read it off the paper and type it in. This opens the newest backup with
#  what you typed -- never with the file on disk -- and says whether it
#  worked.
#
#  WHY THIS IS WORTH A SCRIPT
#
#  "I wrote it down" and "what I wrote down works" are different claims, and
#  only the second one is a backup. A passphrase copied with one wrong
#  character, one missing hyphen, or a capital that should have been small is
#  indistinguishable from a correct one until the day the server is gone --
#  and that is the only day anyone ever finds out.
#
#  Nothing is changed, nothing is written, nothing is printed. The typed
#  passphrase is never echoed, never an argument, and never touches the disk.
#  Run it as often as you like.
# ===========================================================================

set -uo pipefail

DEST="${WAM_BACKUP_DIR:-/root/backups}"
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'

ARCHIVE="$(ls -1t "$DEST"/wam-backup-*.tar.gz.gpg 2>/dev/null | head -1)"
[ -n "$ARCHIVE" ] || { printf '\n  %sno backup found in %s%s\n\n' "$RED" "$DEST" "$OFF"; exit 1; }

printf '\n  Testing against: %s\n' "$(basename "$ARCHIVE")"
printf '  Read the passphrase off your paper and type it. Nothing is shown.\n\n'

read -rsp '  passphrase: ' P; echo
echo

[ -n "$P" ] || { printf '  %snothing typed%s\n\n' "$RED" "$OFF"; exit 1; }

# --passphrase-fd 0 with loopback: the passphrase goes down a pipe that exists
# only for this command. It is never an argument, so it never appears in ps,
# and never a file, so it never reaches the disk.
if printf '%s' "$P" | gpg --quiet --batch --yes --pinentry-mode loopback \
        --passphrase-fd 0 --decrypt "$ARCHIVE" 2>/dev/null | tar tz >/dev/null 2>&1; then
    unset P
    printf '  %sCORRECT.%s What you have written down opens this backup.\n' "$GRN" "$OFF"
    printf '  Keep that paper somewhere that is not this machine.\n\n'
    exit 0
fi

unset P
cat <<EOF
  ${RED}WRONG.${OFF} What you typed does not open this backup.

  Check the paper against these, in order -- they are the usual four:

    a capital letter written small, or the reverse
    a hyphen missing, or one too many
    a digit that looks like a letter: 0 and O, 1 and l
    a trailing space at the end

  ${YEL}Fix the paper now, while the passphrase is still on the server and the
  backups can still be opened.${OFF} If the paper is wrong and the machine is
  lost, every archive it made is a locked box.

  You can also set a new passphrase and let it take a fresh backup:
      bash /usr/local/bin/set-backup-pass.sh

EOF
exit 1

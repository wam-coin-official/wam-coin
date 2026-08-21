#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  pull_backups.sh -- copy the servers' backups onto this machine
# ===========================================================================
#
#      bash scripts/pull_backups.sh HOST [HOST...]
#
#  A backup that exists only on the machine it protects is not a backup. It
#  is a second copy of a file on a disk that is about to fail, and it fails
#  with it. This is the step that makes the other script mean something.
#
#  DIRECTION MATTERS
#  -----------------
#  This pulls. Nothing on the server pushes, and wam-backup.service runs with
#  PrivateNetwork=yes so it could not push if it were told to. A server that
#  can reach out to where the backups live is a server whose compromise
#  reaches them too -- including deleting them, which is what ransomware does
#  first. Here the copies live somewhere the server cannot address, and the
#  credential that moves them belongs to a person.
#
#  VERIFY THERE, THEN COPY
#  -----------------------
#  Each host is asked to verify its own newest archive before anything is
#  transferred: decrypt it, open the wallet inside it, check the ledger. A
#  corrupt archive copied faithfully is still corrupt, and the copy makes it
#  look twice as safe.
#
#  The archives are encrypted with a passphrase this script never sees and
#  the server does not send, so what lands here is unreadable to anyone who
#  takes this laptop.
# ===========================================================================

set -uo pipefail

DEST="${WAM_BACKUP_LOCAL:-$HOME/wam-backups}"
REMOTE_DIR="${WAM_BACKUP_DIR:-/root/backups}"
PULL="${WAM_BACKUP_PULL:-3}"      # newest N per host

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$*"; }
warn() { printf '  %s!!%s    %s\n' "$YEL" "$OFF" "$*"; }

[ "$#" -ge 1 ] || { printf 'usage: %s HOST [HOST...]\n' "${0##*/}" >&2; exit 2; }

rsh() { timeout 300 ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$1" "$2"; }

FAILED=0
PULLED=0

for host in "$@"; do
    printf '\n##### %s #####\n' "$host"
    mkdir -p "$DEST/$host"; chmod 700 "$DEST" "$DEST/$host"

    if ! rsh "$host" 'true' >/dev/null 2>&1; then
        bad "unreachable"; FAILED=1; continue
    fi

    # Ask the host to prove its newest archive restores before we trust it.
    if OUT="$(rsh "$host" "WAM_BACKUP_DIR='$REMOTE_DIR' /usr/local/bin/wam-backup.sh --verify 2>&1")"; then
        printf '%s\n' "$OUT" | grep -E 'ok|FAIL' | sed 's/^/  /'
    else
        bad "the newest backup on $host does not restore -- not pulling it"
        printf '%s\n' "$OUT" | grep -E 'FAIL|error' | sed 's/^/      /' | head -4
        FAILED=1
        continue
    fi

    LIST="$(rsh "$host" "ls -1t '$REMOTE_DIR'/wam-backup-*.tar.gz.gpg 2>/dev/null | head -$PULL")"
    [ -n "$LIST" ] || { bad "no archives found in $REMOTE_DIR"; FAILED=1; continue; }

    while IFS= read -r remote; do
        [ -n "$remote" ] || continue
        base="$(basename "$remote")"
        local_path="$DEST/$host/$base"

        if [ -f "$local_path" ]; then
            ok "already here: $base"
            continue
        fi

        if ! scp -q -o BatchMode=yes "root@$host:$remote" "$local_path"; then
            bad "copy failed: $base"; FAILED=1; continue
        fi
        chmod 600 "$local_path"

        # Compare hashes rather than trusting scp's exit status. A truncated
        # transfer that returned zero is exactly the kind of backup that is
        # discovered on the day it is needed.
        want="$(rsh "$host" "sha256sum '$remote' | cut -d' ' -f1")"
        got="$(sha256sum "$local_path" | cut -d' ' -f1)"
        if [ "$want" = "$got" ] && [ -n "$want" ]; then
            ok "pulled $base ($(stat -c%s "$local_path" 2>/dev/null || stat -f%z "$local_path") bytes, sha matches)"
            PULLED=$((PULLED + 1))
        else
            bad "$base copied but the hash differs -- deleting the local copy"
            rm -f "$local_path"; FAILED=1
        fi
    done <<< "$LIST"
done

printf '\n'
if [ "$FAILED" = 0 ]; then
    printf '  %s%d new archive(s) in %s%s\n' "$GRN" "$PULLED" "$DEST" "$OFF"
    printf '  They are encrypted. Without the passphrase they are noise -- which\n'
    printf '  is the point, and also means losing the passphrase loses the backups.\n\n'
    exit 0
fi
printf '  %ssomething above failed -- read it rather than assuming a copy exists%s\n\n' "$RED" "$OFF"
exit 1

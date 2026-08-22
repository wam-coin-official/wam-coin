#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  wam-backup.sh -- back up the megabyte that cannot be rebuilt
# ===========================================================================
#
#      bash deploy/wam-backup.sh            take a backup, and verify it
#      bash deploy/wam-backup.sh --verify   re-verify the newest one
#
#  WHAT IS AND IS NOT WORTH SAVING
#  -------------------------------
#  Measured on the live host, not guessed at:
#
#      wallets ............   688 KB   irreplaceable
#      pool share ledger ..   254 KB   irreplaceable -- who is owed what
#      config and certs ...   120 KB   irreplaceable in practice
#      chain data .........    35 MB   REPLACEABLE, re-syncs from any peer
#
#  So this copies about a megabyte and deliberately skips the largest thing
#  on the disk. A whole-machine snapshot spends its size on the one part
#  that is already replicated across every node on the network -- the part a
#  blockchain exists to make disposable.
#
#  WHY NOT THE HOSTING PROVIDER'S SNAPSHOT SERVICE
#  -----------------------------------------------
#  A VM snapshot contains wallet.dat, so it contains private keys, so
#  whoever can restore that snapshot can spend those coins. On testnet that
#  means nothing. On mainnet the pool wallet holds miners' money, and paying
#  monthly to keep a copy of its keys on someone else's storage does not
#  remove a risk; it exchanges it for a worse one. This encrypts before
#  anything is written, with a passphrase the provider never sees.
#
#  WHY backupwallet AND NOT cp
#  ---------------------------
#  A wallet file copied while it is being written yields a file that looks
#  fine and opens corrupt. backupwallet asks the node for a consistent copy
#  and is the only supported way to do this on a running wallet. If the node
#  is down there is no safe copy to take, and this fails loudly rather than
#  writing something that will disappoint someone later.
#
#  WHY THE STAGING DIRECTORY IS NOT UNDER /tmp
#  -------------------------------------------
#  wamd.service runs with PrivateTmp=yes, so the daemon gets its own /tmp
#  and cannot see a directory mktemp made in ours. backupwallet then fails
#  with SQLite error 14, "cannot open file", which reads exactly like a
#  corrupt wallet and is not one. Staging next to the destination keeps the
#  path in the namespace the daemon actually has.
#
#  THE PASSPHRASE
#  --------------
#  Read from a root-only file, never passed as an argument -- arguments are
#  visible to every process on the machine.
#
#      IF THAT FILE IS THE ONLY PLACE THE PASSPHRASE EXISTS, EVERY BACKUP
#      THIS SCRIPT MAKES IS A LOCKED BOX YOU CANNOT OPEN ON THE DAY THE
#      SERVER DIES -- WHICH IS THE ONLY DAY YOU WILL WANT IT.
# ===========================================================================

set -uo pipefail

NETWORK="${WAM_NETWORK:-testnet}"
DEST="${WAM_BACKUP_DIR:-/root/backups}"
PASSFILE="${WAM_BACKUP_PASSFILE:-/root/.wam-backup-pass}"
KEEP="${WAM_BACKUP_KEEP:-14}"
DATADIR="${WAM_DATADIR:-/root/.wam}"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'

ok()   { printf '  %sok%s    %s\n'  "$GRN" "$OFF" "$*"; }
bad()  { printf '  %sFAIL%s  %s\n'  "$RED" "$OFF" "$*"; }
warn() { printf '  %s!!%s    %s\n'  "$YEL" "$OFF" "$*"; }
die()  { bad "$*"; exit 1; }

# CHAINDIR is the subdirectory the wallet actually lives under, which is what
# wam-wallet needs to find it again on restore. Mainnet has none.
case "$NETWORK" in
    mainnet) CLI=(wam-cli);            NETFLAG=();          CHAINDIR="" ;;
    testnet) CLI=(wam-cli -testnet);   NETFLAG=(-testnet);  CHAINDIR="testnet3" ;;
    regtest) CLI=(wam-cli -regtest);   NETFLAG=(-regtest);  CHAINDIR="regtest" ;;
    *) die "WAM_NETWORK must be mainnet, testnet or regtest (got '$NETWORK')" ;;
esac

if [ ! -f "$PASSFILE" ]; then
    cat >&2 <<EOF
${RED}error${OFF}: $PASSFILE does not exist.

  Create it, readable by root only:

      printf '%s' 'a long passphrase you choose' > $PASSFILE
      chmod 600 $PASSFILE

  ${YEL}Then write that passphrase somewhere that is not this server.${OFF}
  If this machine is the only place it exists, every backup taken here is
  a locked box on the one day you need to open it.
EOF
    exit 1
fi
[ "$(stat -c '%a' "$PASSFILE")" = "600" ] || warn "$PASSFILE is not mode 600"
[ -s "$PASSFILE" ] || die "$PASSFILE is empty"
command -v gpg >/dev/null || die "gpg is not installed"


# ---------------------------------------------------------------------------
verify_archive() {
# ---------------------------------------------------------------------------
#  Decrypt, unpack, and actually open each wallet with wam-wallet. A backup
#  nobody has restored is a belief, not a backup, and the failure mode of the
#  belief is that it holds right up until the moment it matters.
#
#  Proven in both directions before being trusted: a good copy reports its
#  format and descriptor count, and a deliberately corrupted one fails with
#  "Data is not in recognized format".
# ---------------------------------------------------------------------------
    local archive="$1" work rc=0 found=0 w name
    work="$(mktemp -d -p "$DEST")" || return 1

    if ! gpg --quiet --batch --yes --passphrase-file "$PASSFILE" \
             --decrypt "$archive" 2>/dev/null | tar xz -C "$work" 2>/dev/null; then
        bad "cannot decrypt or unpack $(basename "$archive")"
        rm -rf "$work"; return 1
    fi
    ok "decrypts and unpacks"

    while IFS= read -r w; do
        found=1
        name="$(basename "$(dirname "$w")")"
        # wam-wallet resolves -wallet=NAME under <datadir>/<chain>/wallets/,
        # so reproduce that layout rather than pointing it at a loose file:
        # given a path it reports "Data is not in recognized format" for a
        # perfectly good wallet, which is a misleading way to fail.
        local rdir="$work/restore/$CHAINDIR"
        mkdir -p "$rdir/wallets/$name"
        cp "$w" "$rdir/wallets/$name/wallet.dat"
        if out="$(wam-wallet "${NETFLAG[@]}" -datadir="$work/restore" -wallet="$name" info 2>&1)"; then
            ok "wallet '$name' opens -- $(printf '%s' "$out" | grep -i '^Format:' | tr -d '\n')"
        else
            bad "wallet '$name' will NOT open: $(printf '%s' "$out" | head -1)"
            rc=1
        fi
    done < <(find "$work/wallets" -name 'wallet.dat' 2>/dev/null)

    # A host that runs a node and no wallet -- a seed, or the second Electrum
    # server -- has no wallet to copy, and demanding one made this script
    # build a perfectly good archive of that host's config and certificates
    # and then delete it for failing its own check. The note is written at
    # backup time, exactly as for redis, so "this host has no wallet" stays
    # distinguishable from "the wallet silently went missing".
    if [ "$found" != 1 ]; then
        if [ -f "$work/NO-WALLET-ON-THIS-HOST" ]; then
            ok "no wallet on this host (recorded at backup time)"
        else
            bad "no wallet in the archive, and no note saying why"
            rc=1
        fi
    fi

    if [ -f "$work/redis/dump.rdb" ]; then
        # An RDB begins with the ASCII magic "REDIS". Checking the bytes
        # catches a truncated copy; checking that the file exists does not.
        if [ "$(head -c 5 "$work/redis/dump.rdb")" = "REDIS" ]; then
            ok "redis dump valid ($(stat -c%s "$work/redis/dump.rdb") bytes)"
        else
            bad "redis dump is not an RDB file"; rc=1
        fi
    elif [ -f "$work/NO-REDIS-ON-THIS-HOST" ]; then
        ok "no redis on this host (recorded at backup time)"
    else
        bad "no redis dump and no note saying why"; rc=1
    fi

    if [ -d "$work/config" ]; then
        ok "config tree present ($(find "$work/config" -type f | wc -l) files)"
    else
        bad "no config in the archive"; rc=1
    fi

    rm -rf "$work"
    return $rc
}


mkdir -p "$DEST"; chmod 700 "$DEST"

if [ "${1:-}" = "--verify" ] || [ "${1:-}" = "--verify-all" ]; then
    ALL="$(ls -1t "$DEST"/wam-backup-*.tar.gz.gpg 2>/dev/null)"
    [ -n "$ALL" ] || die "no backup found in $DEST"

    # --verify checks the newest in full. But an archive that stops opening
    # is silent: the passphrase was replaced, or the file rotted on disk, and
    # nothing anywhere says so until the day it is needed. So every archive is
    # at least opened, cheaply, on every verify.
    #
    # This was not hypothetical. Replacing a 12-character passphrase with a
    # 30-character one left the archive taken minutes earlier unopenable by
    # anybody, and --verify reported success because it only ever looked at
    # the newest one.
    NEWEST="$(printf '%s\n' "$ALL" | head -1)"
    printf '\n  verifying %s\n\n' "$(basename "$NEWEST")"
    RC=0
    verify_archive "$NEWEST" || RC=1

    OLD="$(printf '%s\n' "$ALL" | tail -n +2)"
    if [ -n "$OLD" ]; then
        printf '\n  every older archive, can it still be opened at all:\n'
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if [ "${1:-}" = "--verify-all" ]; then
                printf '\n  %s\n' "$(basename "$f")"
                verify_archive "$f" || RC=1
            elif gpg --quiet --batch --yes --passphrase-file "$PASSFILE" \
                     --decrypt "$f" >/dev/null 2>&1; then
                ok "$(basename "$f")"
            else
                bad "$(basename "$f") -- does NOT open with the current
     passphrase. It is a locked box: made before the passphrase was changed,
     or damaged on disk. Nobody can restore it. Move it aside or delete it
     rather than leaving something that looks like a backup and is not."
                RC=1
            fi
        done <<< "$OLD"
    fi

    printf '\n'
    [ "$RC" -eq 0 ] && { printf '  %severy backup here opens%s\n\n' "$GRN" "$OFF"; exit 0; }
    printf '  %sat least one backup here cannot be restored%s\n\n' "$RED" "$OFF"; exit 1
fi


# ===========================================================================
printf '\n  WAM backup -- %s -- %s UTC\n\n' "$NETWORK" "$STAMP"
# ===========================================================================

# Staged beside the destination, NOT in /tmp -- see the header.
STAGE="$(mktemp -d -p "$DEST")" || die "cannot create a staging directory in $DEST"
trap 'rm -rf "$STAGE"' EXIT

# --- wallets ---------------------------------------------------------------
"${CLI[@]}" getblockcount >/dev/null 2>&1 \
    || die "the node is not answering, so no consistent wallet copy can be taken.
     Start it and re-run. Copying wallet.dat behind a running node produces a
     file that opens corrupt, which is worse than no backup at all."

WALLETS="$("${CLI[@]}" listwallets 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"')"
if [ -z "$WALLETS" ]; then
    # Recorded, not merely absent. Without this the verify below rejects the
    # archive and deletes it, and a node-only host ends up with no backup of
    # its config and certificates at all -- which is what happened to the
    # second Electrum server.
    echo "no wallet was loaded on $(hostname) at $STAMP" > "$STAGE/NO-WALLET-ON-THIS-HOST"
    warn "no wallet loaded; recorded a note so a later verify does not read as loss"
fi

for w in $WALLETS; do
    mkdir -p "$STAGE/wallets/$w"
    if "${CLI[@]}" -rpcwallet="$w" backupwallet "$STAGE/wallets/$w/wallet.dat" >/dev/null 2>&1; then
        ok "wallet '$w' ($(stat -c%s "$STAGE/wallets/$w/wallet.dat") bytes)"
    else
        die "backupwallet failed for '$w' -- refusing to write a backup missing a wallet.
     If this says SQLite error 14, the destination is somewhere the daemon
     cannot see; PrivateTmp=yes gives it a different /tmp from this shell."
    fi
done

# --- the pool's share ledger ----------------------------------------------
if command -v redis-cli >/dev/null && systemctl is-active --quiet redis-server 2>/dev/null; then
    RP="$(grep -oP '(?<=^requirepass ).*' /etc/redis/redis.conf 2>/dev/null | head -1 || true)"
    RC=(redis-cli); [ -n "$RP" ] && RC=(redis-cli -a "$RP" --no-auth-warning)

    LAST="$("${RC[@]}" lastsave 2>/dev/null)"
    "${RC[@]}" bgsave >/dev/null 2>&1
    for _ in $(seq 1 30); do
        NOW="$("${RC[@]}" lastsave 2>/dev/null)"
        [ -n "$NOW" ] && [ "$NOW" != "$LAST" ] && break
        sleep 1
    done

    RDBDIR="$("${RC[@]}" config get dir 2>/dev/null | tail -1)"
    RDB="${RDBDIR:-/var/lib/redis}/dump.rdb"
    [ -f "$RDB" ] || RDB=/var/lib/redis/dump.rdb
    if [ -f "$RDB" ]; then
        mkdir -p "$STAGE/redis"; cp "$RDB" "$STAGE/redis/dump.rdb"
        ok "redis ledger ($("${RC[@]}" dbsize 2>/dev/null) keys, $(stat -c%s "$STAGE/redis/dump.rdb") bytes)"
    else
        die "redis is running but its dump was not found -- the share ledger would be lost"
    fi
else
    # Recorded rather than merely absent, so --verify can tell "this host has
    # no pool" apart from "the ledger silently went missing".
    echo "redis was not running on $(hostname) at $STAMP" > "$STAGE/NO-REDIS-ON-THIS-HOST"
    warn "no redis here; recorded a note so a later verify does not read as loss"
fi

# --- configuration, units, certificates ------------------------------------
mkdir -p "$STAGE/config"
for pattern in "$DATADIR/wam.conf" /etc/systemd/system/wam*.service \
               /etc/systemd/system/wam*.timer /etc/nginx /etc/letsencrypt \
               /root/wam-pool/config.json; do
    for f in $pattern; do
        [ -e "$f" ] || continue
        d="$STAGE/config/$(dirname "${f#/}")"
        mkdir -p "$d"; cp -a "$f" "$d/" 2>/dev/null
    done
done
ok "config, units and certificates ($(find "$STAGE/config" -type f | wc -l) files)"

# --- a note for whoever opens this in an emergency -------------------------
cat > "$STAGE/RESTORE.txt" <<EOF
WAM Coin backup -- $STAMP UTC -- network: $NETWORK
From $(hostname), running $(wamd -version 2>/dev/null | head -1)

  gpg --decrypt wam-backup-$STAMP.tar.gz.gpg | tar xz

  wallets/<name>/wallet.dat
      -> <datadir>/${CHAINDIR:+$CHAINDIR/}wallets/<name>/wallet.dat
      check it first:  wam-wallet ${NETFLAG[*]} -datadir=<datadir> -wallet=<name> info

  redis/dump.rdb
      -> stop redis, copy to /var/lib/redis/, chown redis:redis, start

  config/
      mirrors absolute paths from /

Chain data is deliberately NOT here. Re-sync it from any peer -- that is what
a blockchain is for. Wallets and the share ledger are the part no peer can
give back to you.
EOF

# --- encrypt ---------------------------------------------------------------
OUT="$DEST/wam-backup-$STAMP.tar.gz.gpg"
if tar cz -C "$STAGE" --exclude='./tmp.*' . \
     | gpg --quiet --batch --yes --symmetric --cipher-algo AES256 \
           --passphrase-file "$PASSFILE" --output "$OUT" 2>/dev/null; then
    chmod 600 "$OUT"
    ok "encrypted: $(basename "$OUT") ($(stat -c%s "$OUT") bytes)"
else
    die "encryption failed -- no backup written"
fi

# --- and prove it restores now, not on the day it is needed ----------------
printf '\n  verifying what was just written:\n'
if ! verify_archive "$OUT"; then
    rm -f "$OUT"
    die "the archive does not restore -- deleted rather than left to be trusted"
fi

# --- rotate ----------------------------------------------------------------
COUNT="$(ls -1 "$DEST"/wam-backup-*.tar.gz.gpg 2>/dev/null | wc -l)"
if [ "$COUNT" -gt "$KEEP" ]; then
    ls -1t "$DEST"/wam-backup-*.tar.gz.gpg | tail -n +$((KEEP + 1)) | xargs -r rm -f
    ok "rotated, keeping the newest $KEEP of $COUNT"
fi

printf '\n  %s%s%s\n' "$GRN" "$(basename "$OUT")" "$OFF"
printf '  Now pull it off this machine. A backup that exists only here is not one.\n\n'

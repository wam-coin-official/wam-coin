#!/bin/bash
# ===========================================================================
#  wam-facts.sh -- the only thing the reporting key is allowed to run
# ===========================================================================
#
#  Installed at /usr/local/bin/wam-facts on every host and named as a forced
#  command in the reporting key's authorized_keys line:
#
#      restrict,command="/usr/local/bin/wam-facts" ssh-ed25519 AAAA... report
#
#  With that in place the key cannot open a shell, cannot forward a port,
#  cannot run anything else, and cannot be talked into it -- ssh ignores
#  whatever command the client asks for and runs this instead. If the
#  machine that holds the key is ever taken, what the attacker gains here is
#  the ability to read a status line they could mostly infer anyway.
#
#  It prints facts. It changes nothing, reads no key material, and touches
#  no wallet.
# ===========================================================================

set -uo pipefail
CLI=/opt/wam-current-bin/wam-cli

echo "###h";  $CLI -testnet getblockcount 2>/dev/null
echo "###t";  $CLI -testnet getbestblockhash 2>/dev/null
echo "###p";  $CLI -testnet getconnectioncount 2>/dev/null
echo "###m";  free -m | awk '/Mem:/{print $7, $2}'
echo "###s";  free -m | awk '/Swap:/{print $2, $3}'
# tr -dc strips the trailing newline along with the "G", so the next
# section marker lands on the same line and the reader sees "185###u".
# The echo puts the line ending back.
echo "###d";  df -BG --output=avail / | tail -1 | tr -dc 0-9; echo
echo "###u";  cut -d. -f1 /proc/uptime
echo "###l";  cut -d' ' -f1 /proc/loadavg
echo "###g";  git -C /opt/wam rev-parse --short HEAD 2>/dev/null
echo "###b";  ls -t /root/backups/*.gpg 2>/dev/null | head -1 | xargs -r stat -c %Y
echo "###a";  ls /var/lib/wam-reorg/ALARM-* 2>/dev/null | wc -l
echo "###v";  [ -f /etc/update-motd.d/98-wam-version ] && echo behind || echo current
echo "###x"
for u in wamd wam-electrumx@testnet wam-pool wam-dashboard wam-announce \
         wam-miner wam-backup.timer wam-reorg-watch@testnet.timer \
         wam-version-watch.timer wamd-mainnet wam-electrumx@mainnet; do
    # is-active prints "inactive" and exits non-zero, so capture first and
    # decide after -- the obvious `|| echo unknown` yields both words.
    a=$(systemctl is-active "$u" 2>/dev/null); [ -n "$a" ] || a=unknown
    e=$(systemctl is-enabled "$u" 2>/dev/null); [ -n "$e" ] || e=-
    printf '%s %s %s\n' "$u" "$a" "$e"
done
echo "###end"

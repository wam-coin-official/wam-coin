#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  test_harden.sh -- the parts of harden_server.sh that can lock you out
# ===========================================================================
#
#      bash scripts/test/test_harden.sh
#
#  harden_server.sh runs once, as root, on a machine you may be a thousand
#  miles from, and one branch of it decides whether you can still log in
#  tomorrow. It cannot be tested by running it.
#
#  So the two decisions that matter are extracted here and run against the
#  inputs a real server actually presents -- including the empty
#  authorized_keys that most VPS images ship with, which is the case that was
#  wrong.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$HERE/scripts/harden_server.sh"

GREEN=$'\033[32m'; RED=$'\033[31m'; OFF=$'\033[0m'
PASS=0; FAIL=0
ok()   { printf '  %sok%s    %s\n' "$GREEN" "$OFF" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$*";  FAIL=$((FAIL+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 -- expected '$3', got '$2'"; fi; }

# The function under test, lifted verbatim from the script so the two cannot
# drift apart silently. If the extraction stops matching, that is a failure in
# itself.
if ! sed -n '/^    count_keys() {$/,/^    }$/p' "$SCRIPT" | grep -q 'wc -l\|grep -cE'; then
    printf '%sFAIL%s  count_keys() not found in %s -- has it been renamed?\n' \
        "$RED" "$OFF" "$SCRIPT"
    exit 1
fi
eval "$(sed -n '/^    count_keys() {$/,/^    }$/p' "$SCRIPT" | sed 's/^    //')"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "=== counting authorized_keys ==="

# The case that caused a lockout: the file exists and holds nothing.
: > "$T/empty"
check "an empty file counts zero" "$(count_keys "$T/empty")" "0"

check "a missing file counts zero" "$(count_keys "$T/nope")" "0"

printf '\n\n' > "$T/blank"
check "blank lines count zero" "$(count_keys "$T/blank")" "0"

printf '# just a comment\n' > "$T/comment"
check "a comment counts zero" "$(count_keys "$T/comment")" "0"

printf 'ssh-ed25519 AAAAC3Nza w@h\n' > "$T/one"
check "one ed25519 key counts one" "$(count_keys "$T/one")" "1"

printf 'ssh-rsa AAAAB3N a@b\nssh-ed25519 AAAAC3N c@d\n' > "$T/two"
check "two keys count two" "$(count_keys "$T/two")" "2"

printf 'ecdsa-sha2-nistp256 AAAAE2V a@b\n' > "$T/ecdsa"
check "an ecdsa key is counted" "$(count_keys "$T/ecdsa")" "1"

printf 'sk-ssh-ed25519@openssh.com AAAAG a@b\n' > "$T/fido"
check "a FIDO security key is counted" "$(count_keys "$T/fido")" "1"

printf 'command="/bin/true" ssh-ed25519 AAAAC3N a@b\n' > "$T/opts"
check "a key behind options is counted" "$(count_keys "$T/opts")" "1"

# Undercounting is safe -- it leaves passwords on. Overcounting is the one
# that locks somebody out, so garbage must never read as a key.
printf 'this is not a key at all\n' > "$T/junk"
check "prose does not count as a key" "$(count_keys "$T/junk")" "0"

echo
echo "=== it survives the flags the real script runs under ==="
# harden_server.sh sets `-euo pipefail`. Under pipefail a grep that matches
# nothing fails the pipeline, and under -e that aborts the script -- halfway
# through hardening, firewall raised and SSH not yet decided.
cat > "$T/pipefail.sh" <<'EOS'
set -euo pipefail
EOS
sed -n '/^    count_keys() {$/,/^    }$/p' "$SCRIPT" | sed 's/^    //' >> "$T/pipefail.sh"
cat >> "$T/pipefail.sh" <<'EOS'
: > "$1/ak"
n="$(count_keys "$1/ak")"
printf 'reached-end:%s' "$n"
EOS
OUT="$(bash "$T/pipefail.sh" "$T" 2>&1)"; RC=$?
check "no abort on an empty file under -euo pipefail" "$OUT" "reached-end:0"
check "  and it exits clean"                          "$RC"  "0"

echo
echo "=== the lockout decision ==="

decide() {   # $1 user keys, $2 root keys -> what the script does to SSH
    local KEYCOUNT="$1" ROOTKEYS="$2"
    case "$KEYCOUNT$ROOTKEYS" in
        *[!0-9]*|'') echo "refuse"; return ;;
    esac
    if [ "$KEYCOUNT" -eq 0 ] && [ "$ROOTKEYS" -eq 0 ]; then
        echo "keep-passwords"
    else
        echo "disable-passwords"
    fi
}

check "no keys anywhere leaves passwords ON" "$(decide 0 0)" "keep-passwords"
check "a user key allows disabling"          "$(decide 1 0)" "disable-passwords"
check "a root key allows disabling"          "$(decide 0 1)" "disable-passwords"
check "keys for both allows disabling"       "$(decide 2 1)" "disable-passwords"
# The old bug produced exactly this string.
check "a malformed count refuses outright"   "$(decide '0
0' 0)" "refuse"
check "empty input refuses outright"         "$(decide '' '')" "refuse"

echo
echo "=== reading what is actually listening ==="

parse() { awk '
    NR>1 {
        addr = $4; port = $4
        sub(/.*:/,    "", port)
        sub(/:[^:]*$/, "", addr)
        gsub(/^\[|\]$/, "", addr)
        print (addr == "" ? "*" : addr), port
    }'; }

listening() { printf 'State Recv-Q Send-Q Local\n%s\n' "$1" | parse; }

check "ipv4 localhost"  "$(listening 'LISTEN 0 128 127.0.0.1:6379')" "127.0.0.1 6379"
check "ipv4 wildcard"   "$(listening 'LISTEN 0 128 0.0.0.0:6379')"   "0.0.0.0 6379"
check "ipv6 localhost"  "$(listening 'LISTEN 0 128 [::1]:6379')"     "::1 6379"
check "ipv6 wildcard"   "$(listening 'LISTEN 0 128 [::]:6379')"      ":: 6379"

# ::1 is localhost. Reporting it as exposed is a false alarm, and an operator
# who is shown false alarms stops reading the real ones.
is_local() { case "$1" in 127.0.0.1|::1|localhost) echo yes ;; *) echo no ;; esac; }
check "::1 is recognised as localhost" "$(is_local '::1')" "yes"
check ":: is not"                      "$(is_local '::')"  "no"
check "0.0.0.0 is not"                 "$(is_local '0.0.0.0')" "no"

echo
echo "=== awk must not close a pipe early ==="
# `producer | awk '{print; exit}'` kills the producer with SIGPIPE. Under
# `set -o pipefail` the pipeline is then 141, and under `set -e` the enclosing
# assignment aborts the script with no message at all. That is how the SSH
# hardening came to be written, never verified, never reloaded, and reported
# as a success.
big() { seq 1 200000; }

# 200,000 lines against an exit on line 7: the producer is still writing long
# after awk is gone, so this is not a race here even though it is one in real
# use, where the two finish close together and the failure surfaces at random.
#
# The status must be read from $? directly. Writing `( ... ) || RC=$?` would
# put the subshell on the left of a ||, and `set -e` is *disabled* for any
# command whose failure is being tested that way -- so the abort under test
# would not happen, and the test would pass by not reproducing the bug. That
# mistake was made here first.
( set -euo pipefail; V="$(big | awk '/^7$/{print; exit}')"; : "$V" ) 2>/dev/null
check "the early-exit form really does die (141)" "$?" "141"

( set -euo pipefail; V="$(big | awk '$1==7{v=$1} END{print v}')"; : "$V" ) 2>/dev/null
check "reading to END survives pipefail"           "$?" "0"

# And the value is still right -- a fix that returns the wrong answer quietly
# is worse than the crash it replaced.
check "  and returns the same value" \
      "$( set -o pipefail; big | awk '$1==7{v=$1} END{print v}' )" "7"

# The script itself must not contain the hazard. Comments explaining it are
# fine; a live pipeline is not.
LIVE="$(grep -vE '^\s*#' "$SCRIPT" | grep -cE "\|[[:space:]]*awk[^|]*exit[[:space:]]*\}" || true)"
check "no live awk-exit pipeline remains in the script" "${LIVE:-0}" "0"

echo
echo "=== OpenSSH takes the FIRST value, so we must sort first ==="
# Ubuntu cloud images ship 50-cloud-init.conf with PasswordAuthentication yes.
# A 60- file loses that keyword and no other, which is why the drop-in looked
# correct while the setting stayed on.
DROPIN_NAME="$(grep -oE 'DROPIN="\$\{DROPIN_DIR\}/[^"]+"' "$SCRIPT" | head -1 | sed 's/.*\///;s/"//')"
check "the drop-in is named to sort first" "$DROPIN_NAME" "00-wam.conf"

sorts_first() { [ "$1" \< "$2" ] && echo yes || echo no; }
check "00-wam beats 50-cloud-init" "$(sorts_first 00-wam.conf 50-cloud-init.conf)" "yes"
check "60-wam does not"            "$(sorts_first 60-wam.conf 50-cloud-init.conf)" "no"

grep -q 'rm -f "${DROPIN_DIR}/60-wam.conf"' "$SCRIPT" \
    && ok "the old 60-wam.conf is cleaned up on re-run" \
    || bad "a stale 60-wam.conf would be left behind"

echo
echo "=== the script still says what it does ==="
grep -q 'sshd -T' "$SCRIPT" \
    && ok "the change is verified with sshd -T, not just sshd -t" \
    || bad "no sshd -T anywhere: the header promises verification that is not there"
grep -q 'Include\[\[:space:\]\]' "$SCRIPT" \
    && ok "it checks that the drop-in directory is included" \
    || bad "it writes a drop-in without checking sshd reads that directory"

echo
echo "=================================================================="
printf ' %d passed, %d failed\n' "$PASS" "$FAIL"
echo "=================================================================="
[ "$FAIL" -eq 0 ]

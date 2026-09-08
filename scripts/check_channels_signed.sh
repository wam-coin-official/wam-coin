#!/bin/bash
# ===========================================================================
#  check_channels_signed.sh -- is the channel list's signature still current?
# ===========================================================================
#
#      bash scripts/check_channels_signed.sh
#
#  WHY IT EXISTS
#
#  CHANNELS.txt ends by telling its reader:
#
#      gpg --verify CHANNELS.txt.asc CHANNELS.txt
#
#  On 8 September that file was edited twice -- a YouTube channel added, and
#  a Reddit account the file had been denying -- and the signature was not
#  remade either time. A reader following our own instruction would have got
#
#      gpg: BAD signature from "WAM Coin ..."
#
#  which does not read as "they forgot". It reads as: somebody has taken
#  their website and altered the list of which accounts are theirs. That is
#  precisely the attack the signature exists to make visible, and we would
#  have been the ones signalling it.
#
#  BAD is worse than absent. An absent signature is a project that has not
#  got around to it; a BAD one is a project under attack.
#
#  It went stale twice in one day because the thing standing between an edit
#  and a publish was a person remembering. This is that thing, mechanised.
#
#  IT NEEDS NO SECRET KEY
#
#  Only SIGNING-KEY.asc, which is public and in the repository. So it runs in
#  the sweep, in CI, and on a machine that has never seen the USB -- which is
#  the whole point: the failure it catches happens on the laptop where the
#  edit was made, and that laptop holds no secret key.
#
#  exit 0  the signature covers the current bytes
#  exit 1  stale, bad, or the two copies disagree -- do not publish
#  exit 2  the check could not run (no gpg, no key file)
# ===========================================================================

set -uo pipefail

EXPECT="4BD4A8D3AFD43F5CBCB500E23798462FE00ADBA4"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
say()  { printf '  %s\n' "$1"; }
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$1"; }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$1"; }
warn() { printf '  %s??%s    %s\n' "$YLW" "$OFF" "$1"; }

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2

FILE="CHANNELS.txt"
SIG="CHANNELS.txt.asc"
MFILE="site/CHANNELS.txt"
MSIG="site/CHANNELS.txt.asc"

fails=0

echo
echo "${BLD}is the channel list's signature current?${OFF}"
echo

command -v gpg >/dev/null 2>&1 || { warn "gpg is not installed -- cannot check"; echo; exit 2; }
[ -f SIGNING-KEY.asc ] || { warn "SIGNING-KEY.asc is missing -- cannot check"; echo; exit 2; }

for f in "$FILE" "$SIG" "$MFILE" "$MSIG"; do
    [ -f "$f" ] || { bad "$f does not exist"; fails=$((fails + 1)); }
done
[ "$fails" -eq 0 ] || {
    echo
    say "If it is only the .asc files: the list has never been signed."
    say "    bash scripts/sign_channels.sh"
    echo; exit 1; }

# Same cross-check check_release_signed.sh makes, for the same reason: this
# fingerprint is written in several files, and the copy nobody looks at is the
# copy that is wrong.
norm() { printf '%s' "$1" | tr -d '[:space:]' | tr 'a-f' 'A-F'; }
if printf '%s' "$(norm "$(cat SECURITY.md 2>/dev/null)")" | grep -q "$(norm "$EXPECT")"; then
    ok "the fingerprint here matches SECURITY.md"
else
    bad "this script and SECURITY.md name different fingerprints"
    fails=$((fails + 1))
fi

# ---- one signature, two copies -------------------------------------------
#
# The signature covers bytes, not a filename. If the repository copy and the
# copy the website serves differ by a single comma, then whichever one this
# .asc was made from verifies and the other does not -- and the one that does
# not is the one the public downloads.
if cmp -s "$FILE" "$MFILE"; then
    ok "CHANNELS.txt and site/CHANNELS.txt are byte-identical"
else
    bad "CHANNELS.txt and site/CHANNELS.txt DIFFER"
    say "One signature cannot cover both. The website serves the second one."
    say "    cp CHANNELS.txt site/CHANNELS.txt   &&   bash scripts/sign_channels.sh"
    fails=$((fails + 1))
fi
if cmp -s "$SIG" "$MSIG"; then
    ok "both .asc copies are byte-identical"
else
    bad "CHANNELS.txt.asc and site/CHANNELS.txt.asc DIFFER"
    say "The site is serving a different signature than the repository."
    fails=$((fails + 1))
fi

# ---- does it actually verify ---------------------------------------------
#
# In a throwaway keyring built from the public key alone, exactly as a
# stranger's would be. Reading GnuPG's --status-fd rather than its English
# prose: "Good signature" is translated, and a check that depends on the
# machine's language is a check that passes for the wrong reason abroad.
T="$(mktemp -d)" || { warn "cannot create a temporary keyring"; echo; exit 2; }
vclean() { gpgconf --homedir "$T" --kill all >/dev/null 2>&1; rm -rf "$T"; }
chmod 700 "$T" 2>/dev/null
gpg --homedir "$T" --batch --quiet --import SIGNING-KEY.asc 2>/dev/null \
    || { vclean; warn "SIGNING-KEY.asc would not import -- cannot check"; echo; exit 2; }

out="$(gpg --homedir "$T" --status-fd 1 --verify "$SIG" "$FILE" 2>/dev/null)"
vclean

if printf '%s' "$out" | grep -q "GOODSIG"; then
    got="$(printf '%s' "$out" | grep -m1 "VALIDSIG" | awk '{print $3}')"
    if [ "$got" = "$EXPECT" ]; then
        ok "the signature covers the current CHANNELS.txt, by the published key"
    else
        bad "signed by $got, which is not the fingerprint we publish"
        fails=$((fails + 1))
    fi
elif printf '%s' "$out" | grep -q "BADSIG\|EXPKEYSIG\|REVKEYSIG"; then
    bad "BAD signature: CHANNELS.txt has been edited since it was signed"
    say ""
    say "A reader running the command CHANNELS.txt itself gives them sees"
    say "\"BAD signature\", which reads as an impostor having taken our site."
    say "Do not publish. Re-sign it, with the USB plugged in:"
    say ""
    say "    bash scripts/sign_channels.sh"
    say ""
    fails=$((fails + 1))
else
    bad "the signature does not verify, and not because the key is wrong"
    printf '%s\n' "$out" | sed 's/^/          /' | head -6
    fails=$((fails + 1))
fi

# ---- and against what somebody who CLONES the repository gets --------------
#
# This is the check that was missing, and its absence produced a green tick on
# 8 September while the committed pair was BADSIG.
#
# The working tree is not what the public receives. .gitattributes says
# `* text=auto eol=lf`, so a file written with CRLF -- which is what an editor
# on Windows does -- is silently normalised to LF when it is added. The file
# that was signed and the file that was committed then differ by 142 bytes,
# both are correct on their own terms, and the signature covers only one of
# them. Everything above passed, because everything above read the copy on
# this disk.
#
# So: verify the bytes git actually holds, with the signature git actually
# holds. That pair is what `git clone` hands a stranger, and CHANNELS.txt
# tells that stranger to check it.
if git rev-parse --git-dir >/dev/null 2>&1; then
    C="$(mktemp -d)" || { warn "cannot create a temporary directory"; echo; exit 2; }
    cclean() { gpgconf --homedir "$C/h" --kill all >/dev/null 2>&1; rm -rf "$C"; }
    if git show "HEAD:$FILE" > "$C/f" 2>/dev/null && git show "HEAD:$SIG" > "$C/s" 2>/dev/null; then
        mkdir -p "$C/h"; chmod 700 "$C/h"
        gpg --homedir "$C/h" --batch --quiet --import SIGNING-KEY.asc 2>/dev/null
        cout="$(gpg --homedir "$C/h" --status-fd 1 --verify "$C/s" "$C/f" 2>/dev/null)"
        if printf '%s' "$cout" | grep -q "GOODSIG"; then
            ok "and it verifies against the committed bytes, which is what a clone gets"
        else
            bad "the COMMITTED pair does not verify -- a clone of this repository gets BAD signature"
            say ""
            say "  committed  $(wc -c < "$C/f" | tr -d ' ') bytes"
            say "  on disk    $(wc -c < "$FILE" | tr -d ' ') bytes"
            say ""
            say "If those two numbers differ, the file was signed before git"
            say "normalised its line endings. Make the working copy LF, then"
            say "sign the LF bytes:"
            say ""
            say "    sed -i 's/\\r\$//' $FILE $MFILE"
            say "    bash scripts/sign_channels.sh"
            say ""
            fails=$((fails + 1))
        fi
    else
        warn "CHANNELS.txt or its signature is not committed yet -- only the working copy was checked"
    fi
    cclean
else
    warn "not a git repository -- only the working copy was checked"
fi

echo
if [ "$fails" -gt 0 ]; then
    printf '  %s%d problem(s)%s\n\n' "$RED" "$fails" "$OFF"
    exit 1
fi
printf '  %s%severything the public can verify, verifies%s\n\n' "$GRN" "$BLD" "$OFF"
exit 0

#!/bin/bash
# ===========================================================================
#  sign_channels.sh -- sign the canonical channel list with the offline key
# ===========================================================================
#
#      bash scripts/sign_channels.sh            # key on D:
#      bash scripts/sign_channels.sh /e         # key on E:
#
#  RUN THIS YOURSELF, IN YOUR OWN TERMINAL. It asks for the passphrase, and
#  a passphrase typed anywhere else is a passphrase somebody else has seen.
#
#  WHY IT EXISTS
#
#  CHANNELS.txt tells its reader to run
#
#      gpg --verify CHANNELS.txt.asc CHANNELS.txt
#
#  and that file did not exist. The list that says which accounts are ours --
#  the one thing standing between a reader and an impostor -- carried the
#  authority of a commit history, which anybody who takes the repository also
#  takes. A signature is the part that cannot be taken.
#
#  It is a script and not a note in a runbook because the list changes: three
#  revisions in four weeks, and each one invalidates the last signature. A
#  ritual performed by hand is performed until it is forgotten, and this
#  project has now forgotten the same class of thing three times in one day.
#
#  WHERE THE KEY GOES, AND WHERE IT DOES NOT
#
#  The secret key lives on the USB and nowhere else -- this laptop's keyring
#  holds no secret key at all, which is the correct state and worth keeping.
#  So the temporary GnuPG home is created ON THE USB, the key is imported
#  there, and the directory is destroyed afterwards whatever happens. The key
#  never touches the internal disk, where a delete is not an erase.
#
#  It verifies its own signature before it finishes, in a throwaway keyring,
#  against the fingerprint published in SECURITY.md. A signing step that does
#  not check its own output is how a release goes out signed by nothing.
# ===========================================================================

set -uo pipefail

EXPECT="4BD4A8D3AFD43F5CBCB500E23798462FE00ADBA4"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
say()  { printf '  %s\n' "$1"; }
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$1"; }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$1"; }

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
USB="${1:-/d}"
KEY="$USB/wam-secret-BACKUP.asc"
FILE="$ROOT/CHANNELS.txt"
SIG="$ROOT/CHANNELS.txt.asc"
MIRROR="$ROOT/site/CHANNELS.txt"

echo
echo "${BLD}signing the canonical channel list${OFF}"
say "file : $FILE"
say "key  : $KEY"
echo

[ -f "$FILE" ] || { bad "CHANNELS.txt is not there"; echo; exit 2; }
[ -f "$KEY" ]  || {
    bad "the key is not at $KEY"
    say "Is the USB plugged in? Pass its mount point, e.g."
    say "    bash scripts/sign_channels.sh /e"
    echo; exit 2; }

# The mirror must already match, or we sign one thing and serve another.
if ! cmp -s "$FILE" "$MIRROR"; then
    bad "CHANNELS.txt and site/CHANNELS.txt differ"
    say "Signing now would produce a signature that is valid for the"
    say "repository copy and invalid for the one the website serves."
    say "    cp CHANNELS.txt site/CHANNELS.txt"
    echo; exit 1
fi
ok "both copies are identical, so one signature covers both"

# ---- the temporary keyring, on the USB, destroyed on any exit -------------
TMPHOME="$USB/.wam-sign-$$"
cleanup() {
    GNUPGHOME="$TMPHOME" gpgconf --kill all >/dev/null 2>&1
    rm -rf "$TMPHOME" 2>/dev/null
}
trap cleanup EXIT INT TERM

rm -rf "$TMPHOME"
mkdir -p "$TMPHOME" || { bad "cannot create $TMPHOME -- is the USB writable?"; echo; exit 2; }
chmod 700 "$TMPHOME" 2>/dev/null
export GNUPGHOME="$TMPHOME"

if ! gpg --batch --quiet --import "$KEY" 2>/dev/null; then
    bad "the key would not import"
    say "Check that $KEY is the GPG secret key backup and not something else."
    echo; exit 1
fi

if ! gpg --batch --with-colons --list-secret-keys 2>/dev/null \
     | grep -q "^fpr:::::::::$EXPECT:"; then
    bad "the key on the USB is not the one this project publishes"
    say "  expected : $EXPECT"
    say "This is either the wrong USB or the wrong key. Do not sign."
    echo; exit 1
fi
ok "the key on the USB is the fingerprint published in SECURITY.md"

# ---- sign ----------------------------------------------------------------
echo
say "${YLW}GnuPG will now ask for the passphrase.${OFF}"
echo
rm -f "$SIG"
if ! gpg --detach-sign --armor --local-user "$EXPECT" --output "$SIG" "$FILE"; then
    bad "signing failed -- nothing was written"
    echo; exit 1
fi
[ -s "$SIG" ] || { bad "the signature file is empty"; rm -f "$SIG"; echo; exit 1; }
ok "signature written to CHANNELS.txt.asc"

# ---- verify what was just produced, as a stranger would ------------------
#
# Not in the keyring that just signed it -- that one holds the secret key and
# would say yes to anything it made. A separate keyring built from the public
# key file, with the fingerprint compared explicitly, is the same check
# verify_release.sh runs, and for the same reason.
VHOME="$(mktemp -d)"
chmod 700 "$VHOME"
gpg --homedir "$VHOME" --batch --quiet --import "$ROOT/SIGNING-KEY.asc" 2>/dev/null
out="$(gpg --homedir "$VHOME" --status-fd 1 --verify "$SIG" "$FILE" 2>/dev/null)"
rm -rf "$VHOME"

if ! printf '%s' "$out" | grep -q "GOODSIG"; then
    bad "the signature this script just made does not verify"
    rm -f "$SIG"
    echo; exit 1
fi
got="$(printf '%s' "$out" | grep -m1 "VALIDSIG" | awk '{print $3}')"
if [ "$got" != "$EXPECT" ]; then
    bad "signed by $got, which is not the published fingerprint"
    rm -f "$SIG"
    echo; exit 1
fi
ok "it verifies against SIGNING-KEY.asc, by the published fingerprint"

cp "$SIG" "$ROOT/site/CHANNELS.txt.asc" && ok "copied to site/CHANNELS.txt.asc"

echo
echo "  ${GRN}${BLD}the channel list is signed${OFF}"
say ""
say "The USB keyring has been destroyed; the key never touched this disk."
say ""
say "One thing to remember: the signature covers these exact bytes. Any"
say "edit to CHANNELS.txt, down to a comma, invalidates it -- so run this"
say "again after every revision, and commit the two together."
echo

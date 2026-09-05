#!/bin/bash
# ===========================================================================
#  sign_release.sh -- sign a built release with the offline key, after
#                     checking that the bytes are what they claim to be
# ===========================================================================
#
#      bash scripts/sign_release.sh ~/Downloads          # key on D:
#      bash scripts/sign_release.sh ~/Downloads /e       # key on E:
#
#  RUN THIS YOURSELF, IN YOUR OWN TERMINAL. It asks for the passphrase, and a
#  passphrase typed anywhere else is a passphrase somebody else has seen.
#
#  WHY IT EXISTS
#
#  The GitHub runner builds the release and cannot sign it: the secret key is
#  on a USB stick and is never on a machine that faces the internet. So there
#  is a gap between "built" and "signed" that a person has to close by hand,
#  and RELEASING.md used to close it with four commands typed from memory:
#
#      gh release download v0.1.7 -p SHA256SUMS
#      gpg --detach-sign --armor SHA256SUMS
#      ...
#
#  Two things are wrong with that. The small one is that `gh` is not installed
#  on the machine that holds the key, so the first command fails and the
#  procedure stops at its first line. The large one is the second command:
#  it signs whatever file is sitting there.
#
#  WHAT A SIGNATURE OVER AN UNCHECKED FILE MEANS
#
#  SHA256SUMS is not the release. It is a list of promises about the release,
#  and it arrives over the network from a service this project does not own.
#  Signing it without looking at the files it describes converts "GitHub gave
#  me this list" into "the founder personally vouches for these bytes" -- and
#  that is exactly the sentence every reader of verify_release.sh is trusting.
#  The key's whole value is that it says something the network cannot say.
#
#  So this refuses to sign until every file named in SHA256SUMS is present in
#  the directory and hashes to the value written beside it. Not
#  --ignore-missing, which is right for a reader who wanted one package and
#  wrong for the person whose signature will cover all of them: you cannot
#  vouch for a file you never downloaded.
#
#  The packages are about 11 MB together. Download both.
#
#  WHERE THE KEY GOES, AND WHERE IT DOES NOT
#
#  The temporary GnuPG home is created ON THE USB, the key is imported there,
#  and the directory is destroyed afterwards whatever happens. The key never
#  touches the internal disk, where a delete is not an erase. This is the same
#  arrangement sign_channels.sh uses, for the same reason.
#
#  It verifies its own signature before it finishes, in a throwaway keyring
#  built from SIGNING-KEY.asc, with the fingerprint compared explicitly. A
#  signing step that does not check its own output is how a release goes out
#  signed by nothing.
# ===========================================================================

set -uo pipefail

EXPECT="4BD4A8D3AFD43F5CBCB500E23798462FE00ADBA4"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
say()  { printf '  %s\n' "$1"; }
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$1"; }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$1"; }

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"

DIR="${1:-.}"
USB="${2:-/d}"
KEY="$USB/wam-secret-BACKUP.asc"

cd "$DIR" 2>/dev/null || { echo "no such directory: $DIR" >&2; exit 2; }
DIR="$(pwd)"

echo
echo "${BLD}signing a release${OFF}"
say "files : $DIR"
say "key   : $KEY"
echo

command -v sha256sum >/dev/null 2>&1 || { bad "sha256sum is not on PATH"; echo; exit 2; }
command -v gpg       >/dev/null 2>&1 || { bad "gpg is not on PATH -- run this in Git Bash, not PowerShell"; echo; exit 2; }

[ -f SHA256SUMS ] || {
    bad "SHA256SUMS is not in $DIR"
    say "Download it, and both packages, from the release page."
    echo; exit 2; }

# ---- 1. is the list itself intact? ---------------------------------------
#
# A carriage return here would be signed along with everything else, and the
# signature would be perfectly valid over a file that `sha256sum -c` cannot
# read on the machines that matter. The signer is on Windows; the readers are
# not. Opening the file in Notepad and saving it is enough to do this, and
# nothing downstream would ever say why.
#
# Counted with tr, not matched with grep. The first version of this check was
#
#     LC_ALL=C grep -q $'\r' SHA256SUMS
#
# and it found nothing in a file that measurably held two carriage returns,
# because grep on Git Bash opens files in text mode and strips them before the
# pattern ever sees them. It reported clean and exited 0 -- a check that cannot
# fail is not a check, and this repository has now met that shape three times
# (grep -P refusing on this locale, the python3 stub, this). tr reads bytes.
if [ "$(tr -dc '\r' < SHA256SUMS | wc -c)" -gt 0 ]; then
    bad "SHA256SUMS contains carriage returns"
    say "Something on this machine rewrote its line endings -- Notepad, or an"
    say "editor set to CRLF. Signing it would produce a valid signature over a"
    say "file Linux readers cannot check. Download it again and do not open it."
    echo; exit 1
fi

if [ -f SHA256SUMS.asc ]; then
    say "${YLW}SHA256SUMS.asc already exists here; it will be replaced.${OFF}"
fi

# A browser does not overwrite; it renames. Downloading SHA256SUMS into a
# directory that already holds one produces `SHA256SUMS (1)`, and every tool
# after that -- this script included -- goes on reading the old file. On the
# day v0.1.7 was signed there was a v0.1.0 SHA256SUMS sitting in Downloads
# from months earlier, so the person about to sign would have been shown the
# wrong list with no hint that a newer one had arrived beside it.
#
# The version check below would have refused, which is the safe outcome and
# not a clear one: it would have said "this is v0.1.0" about a v0.1.7
# download. Naming the actual cause is the difference between a stop and an
# explanation.
shopt -s nullglob
DUPES=(SHA256SUMS\ \(*\) SHA256SUMS.[0-9]* SHA256SUMS-[0-9]*)
shopt -u nullglob
if [ "${#DUPES[@]}" -gt 0 ]; then
    bad "there is more than one SHA256SUMS in this directory"
    for d in "${DUPES[@]}"; do say "    $d"; done
    say ""
    say "Your browser renamed the new download because an older SHA256SUMS was"
    say "already here, so this script would sign the OLD one. Use an empty"
    say "directory:"
    say "    mkdir ~/Downloads/wam-$(date +%Y%m%d) && move the three files there"
    echo; exit 1
fi

# ---- 2. is every promised file here, and does it keep its promise? -------
#
# Two separators exist and both are legal. coreutils writes `hash  name` for a
# file read in text mode and `hash *name` for one read in binary; the Linux
# runner produces the first, and sha256sum on Git Bash produces the second, so
# a check written against either alone is a check that only works where it was
# written. `sha256sum -c` accepts both, and so must this. A leading `\` means
# coreutils escaped a name containing a newline or a backslash, which no
# release artifact has any business doing.
count=0
while read -r _hash name; do
    [ -n "${name:-}" ] || continue
    name="${name#\*}"
    case "$name" in
        '\'*) bad "SHA256SUMS holds an escaped file name: $name"; echo; exit 1 ;;
        */*)  bad "SHA256SUMS names a path, not a file: $name"; echo; exit 1 ;;
    esac
    if [ ! -f "$name" ]; then
        bad "SHA256SUMS lists a file that is not here: $name"
        say ""
        say "Every file in the list has to be downloaded before it can be"
        say "signed. Your signature will say these bytes are ours; you cannot"
        say "say that about a file you have not got. Both packages are on the"
        say "release page and come to about 11 MB."
        echo; exit 1
    fi
    count=$((count + 1))
done < SHA256SUMS

if [ "$count" -eq 0 ]; then
    bad "SHA256SUMS is empty -- there is nothing to sign for"
    echo; exit 1
fi

res="$(sha256sum -c SHA256SUMS 2>/dev/null)"
failed="$(printf '%s\n' "$res" | grep -c ': FAILED$' || true)"
passed="$(printf '%s\n' "$res" | grep -c ': OK$' || true)"

if [ "${failed:-0}" -gt 0 ] || [ "${passed:-0}" -ne "$count" ]; then
    bad "the files do not match the list"
    printf '%s\n' "$res" | sed 's/^/       /'
    say ""
    say "Do not sign this. Either the download is damaged, or what is on the"
    say "release page is not what the runner built."
    echo; exit 1
fi
ok "$passed file(s) present and matching the list, byte for byte"

# ---- 3. is this the release this checkout describes? ---------------------
#
# The names carry the version. Signing v0.1.6's list while the repository sits
# at v0.1.7 is a plausible mistake on a day when both are in ~/Downloads, and
# it produces a signature that is entirely valid and entirely about the wrong
# release. patch_upstream.py holds what the binaries report, so it is the one
# to ask.
want="$(sed -n 's/^WAM_CLIENT_VERSION *= *"\([0-9.]*\)".*/\1/p' "$ROOT/scripts/patch_upstream.py" | head -1)"
got="$(sed -n 's/.*wam-\(coin\|miner\)-v\([0-9][0-9.]*\)-.*/\2/p' SHA256SUMS | sort -u)"

if [ -z "$got" ]; then
    say "${YLW}no version could be read from the file names; not checked${OFF}"
elif [ "$(printf '%s\n' "$got" | wc -l)" -ne 1 ]; then
    bad "SHA256SUMS mixes versions: $(printf '%s ' $got)"
    say "One signature would cover two releases. Sign them separately."
    echo; exit 1
elif [ -n "$want" ] && [ "$got" != "$want" ]; then
    if [ "${WAM_SIGN_ANY_VERSION:-0}" = "1" ]; then
        say "${YLW}signing v$got from a v$want checkout (WAM_SIGN_ANY_VERSION=1)${OFF}"
    else
        bad "this is v$got, but this checkout is v$want"
        say ""
        say "  files here     : v$got"
        say "  patch_upstream : v$want"
        say ""
        say "If you meant to sign an older release, check that tag out, or run"
        say "again with WAM_SIGN_ANY_VERSION=1."
        echo; exit 1
    fi
else
    ok "v$got, which is what this checkout builds"
fi

# ---- 4. the key, on the USB, in a keyring that dies with this script -----
[ -f "$KEY" ] || {
    bad "the key is not at $KEY"
    say "Is the USB plugged in? Pass its mount point, e.g."
    say "    bash scripts/sign_release.sh $DIR /e"
    echo; exit 2; }

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

# ---- 5. sign ------------------------------------------------------------
echo
say "${YLW}GnuPG will now ask for the passphrase.${OFF}"
echo
rm -f SHA256SUMS.asc
if ! gpg --detach-sign --armor --local-user "$EXPECT" --output SHA256SUMS.asc SHA256SUMS; then
    bad "signing failed -- nothing was written"
    echo; exit 1
fi
[ -s SHA256SUMS.asc ] || { bad "the signature file is empty"; rm -f SHA256SUMS.asc; echo; exit 1; }
ok "signature written to SHA256SUMS.asc"

# ---- 6. check it the way a stranger will --------------------------------
#
# Not in the keyring that just signed it -- that one holds the secret key and
# would say yes to anything it made.
VHOME="$(mktemp -d)"
chmod 700 "$VHOME"
gpg --homedir "$VHOME" --batch --quiet --import "$ROOT/SIGNING-KEY.asc" 2>/dev/null
out="$(gpg --homedir "$VHOME" --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS 2>/dev/null)"
rm -rf "$VHOME"

if ! printf '%s' "$out" | grep -q "GOODSIG"; then
    bad "the signature this script just made does not verify"
    rm -f SHA256SUMS.asc
    echo; exit 1
fi
signer="$(printf '%s' "$out" | grep -m1 "VALIDSIG" | awk '{print $3}')"
if [ "$signer" != "$EXPECT" ]; then
    bad "signed by $signer, which is not the published fingerprint"
    rm -f SHA256SUMS.asc
    echo; exit 1
fi
ok "it verifies against SIGNING-KEY.asc, by the published fingerprint"

cleanup
trap - EXIT INT TERM

echo
echo "  ${GRN}${BLD}the release is signed${OFF}"
say ""
say "  $DIR/SHA256SUMS.asc"
say ""
say "The USB keyring has been destroyed; the key never touched this disk."
say ""
say "Next, on the release page:"
say "  1. upload SHA256SUMS.asc as an asset"
say "  2. take the release out of draft"
say "  3. check it as a stranger would, in a clean directory:"
say "         bash scripts/verify_release.sh <that directory>"
say ""
say "Until step 2, nobody can download it -- which is the point of the draft."
echo

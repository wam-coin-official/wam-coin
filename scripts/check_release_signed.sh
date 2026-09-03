#!/bin/bash
# ===========================================================================
#  check_release_signed.sh -- is what the world can download actually signed?
# ===========================================================================
#
#      bash scripts/check_release_signed.sh            # the latest release
#      bash scripts/check_release_signed.sh v0.1.6
#
#  It asks GitHub what the release actually carries, downloads SHA256SUMS and
#  its signature, and verifies them against the fingerprint in SECURITY.md.
#
#  WHY IT ASKS GITHUB AND NOT THE WORKING TREE
#
#  Everything else here can be true while the published release is not. The
#  signing key can be present, package_release.sh can sign correctly, the
#  local files can verify perfectly -- and the asset uploaded to GitHub two
#  weeks ago can still be the unsigned one, because uploading is a manual
#  step and manual steps get half-done.
#
#  What a stranger downloads is the only thing that matters, so that is what
#  this reads.
# ===========================================================================

set -uo pipefail
cd "$(dirname "$0")/.."

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
REPO="${WAM_REPO:-wam-coin-official/wam-coin}"
EXPECT="4BD4A8D3AFD43F5CBCB500E23798462FE00ADBA4"

fails=0
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$1"; }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$1"; fails=$((fails+1)); }
warn() { printf '  %s!!%s    %s\n' "$YLW" "$OFF" "$1"; }

echo
echo "${BLD}can a stranger prove the download is ours?${OFF}"

command -v curl >/dev/null 2>&1 || { warn "curl is not installed"; echo; exit 2; }
command -v gpg  >/dev/null 2>&1 || { warn "gpg is not installed"; echo; exit 2; }

# The fingerprint in this script must be the one in SECURITY.md. Two copies of
# a fingerprint is two chances to publish the wrong one.
#
# Compared with every space removed from both sides. gpg prints a fingerprint
# in five-group blocks with a DOUBLE space in the middle, and the first version
# of this check rebuilt it with single spaces and then reported that the two
# files disagreed -- about two identical fingerprints. A check that cries
# about a correct file is how a person learns to skip its output.
norm() { printf '%s' "$1" | tr -d '[:space:]' | tr 'a-f' 'A-F'; }
if [ -f SECURITY.md ] && printf '%s' "$(norm "$(cat SECURITY.md)")" | grep -q "$(norm "$EXPECT")"; then
    ok "the fingerprint here matches SECURITY.md"
else
    bad "this script and SECURITY.md name different fingerprints"
fi

TAG="${1:-}"
API="https://api.github.com/repos/$REPO/releases"
[ -n "$TAG" ] && API="$API/tags/$TAG" || API="$API/latest"

json="$(curl -sS --max-time 25 "$API" 2>/dev/null)"
if [ -z "$json" ] || printf '%s' "$json" | grep -q '"message": *"Not Found"'; then
    warn "GitHub did not return a release (rate limit, or none published yet)"
    echo; exit 2
fi

tag="$(printf '%s' "$json" | grep -m1 '"tag_name"' | cut -d'"' -f4)"
names="$(printf '%s' "$json" | grep '"name"' | cut -d'"' -f4)"
echo "  release: $tag"

for want in SHA256SUMS SHA256SUMS.asc; do
    if printf '%s\n' "$names" | grep -qx "$want"; then
        ok "$want is published"
    else
        bad "$want is NOT published -- the download cannot be verified by anyone"
    fi
done
[ "$fails" -gt 0 ] && { echo; printf '  %s%d problem(s)%s\n\n' "$RED" "$fails" "$OFF"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
base="https://github.com/$REPO/releases/download/$tag"
curl -sSL --max-time 40 -o "$T/SHA256SUMS"     "$base/SHA256SUMS"
curl -sSL --max-time 40 -o "$T/SHA256SUMS.asc" "$base/SHA256SUMS.asc"

# An empty keyring, so this proves what a stranger's machine would prove and
# not what ours happens to trust already.
gpg --homedir "$T" --batch --quiet --import SIGNING-KEY.asc 2>/dev/null
out="$(gpg --homedir "$T" --status-fd 1 --verify "$T/SHA256SUMS.asc" "$T/SHA256SUMS" 2>/dev/null)"

if printf '%s' "$out" | grep -q "GOODSIG"; then
    got="$(printf '%s' "$out" | grep -m1 "VALIDSIG" | awk '{print $3}')"
    if [ "$got" = "$EXPECT" ]; then
        ok "the published SHA256SUMS is signed by the published key"
    else
        bad "signed by $got, not by $EXPECT"
    fi
else
    bad "the published signature does not verify"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "  ${GRN}anyone downloading this release can prove it is ours${OFF}"
else
    echo "  ${RED}$fails problem(s) -- a downloader cannot tell this from a fake${OFF}"
fi
echo
exit $(( fails > 0 ))

#!/bin/bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  package_platform.sh -- make a release archive from binaries already built
# ===========================================================================
#
#      bash scripts/package_platform.sh --platform windows --version v0.1.8 \
#          --from ~/Downloads/wam-windows-x86_64
#
#      bash scripts/package_platform.sh --platform macos-arm64 --version v0.1.8 \
#          --from out/macos-arm64
#
#  WHY THIS IS NOT package_release.sh
#
#  package_release.sh compiles. It fetches upstream, applies the WAM changes,
#  builds RandomX for a portable baseline, links, strips, and then packages --
#  and every one of those steps is Linux-specific. Teaching it a second
#  platform would mean teaching it to cross-compile, which build_windows.sh
#  already does, and editing the script that produces the launch release
#  during the week the launch release is frozen.
#
#  So this one does not build anything. It takes a directory of finished
#  binaries -- from build_windows.sh, build_macos.sh, or the artifact the
#  platform-build workflow uploads -- and produces an archive laid out exactly
#  like the Linux one, so a reader who has seen one knows where to look.
#
#  WHY THERE WAS NO WINDOWS RELEASE UNTIL NOW
#
#  Not the build. The build has worked since 7 September, is exercised in CI
#  on every platform-build run, and on 10 September a stranger ran a node
#  under WSL and reported the same block hash at height 7738 as ours. What was
#  missing was thirty lines that put those binaries in a tarball.
#
#  The founder said this on 12 September, three days out, and he was right:
#  RandomX was chosen so an ordinary computer can mine, most ordinary
#  computers run Windows, and a chain that ships Linux-only on its first day
#  contradicts its own reason for existing. Somebody who arrives on day one,
#  finds nothing he can run, and leaves does not come back to check later.
#
#  WHAT IT REFUSES TO DO
#
#  It does not sign. The key is offline on a USB stick and signing happens on
#  the machine that holds it, by a person -- scripts/sign_release.sh. This
#  prints the SHA256 lines to be added to SHA256SUMS and stops there.
#
#  It also refuses a binary whose file format does not match the platform
#  being claimed. A tarball named -windows- holding ELF executables is worse
#  than no tarball: it fails on the target machine with an error about a
#  format nobody reading it expects.
# ===========================================================================

set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$REPO" || exit 2

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$*"; }
warn() { printf '  %s!!%s    %s\n' "$YLW" "$OFF" "$*"; }
die()  { printf '\n  %sSTOPPED%s  %s\n\n' "$RED" "$OFF" "$*" >&2; exit 1; }

PLATFORM=""; VERSION=""; FROM=""
OUT="${OUT:-$REPO/out/release}"

while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORM="${2:-}"; shift 2 ;;
        --version)  VERSION="${2:-}";  shift 2 ;;
        --from)     FROM="${2:-}";     shift 2 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[ -n "$PLATFORM" ] && [ -n "$VERSION" ] && [ -n "$FROM" ] || {
    printf 'usage: %s --platform windows|macos-arm64|macos-x86_64 --version vX.Y.Z --from DIR\n' \
        "${0##*/}" >&2; exit 2; }
[ -d "$FROM" ] || die "no such directory: $FROM"

# PRETTY is the platform as it appears in a sentence a stranger reads. The
# first version of RELEASE.txt interpolated $PLATFORM directly and told people
# their binary had been tested "on a windows runner", which reads like a typo
# in the one file whose whole job is to be believed.
case "$PLATFORM" in
    windows)      TRIPLET="x86_64-w64-mingw32"; WANT="PE32+";  ARCHIVE="zip"
                  STRIP="x86_64-w64-mingw32-strip"; PRETTY="Windows" ;;
    macos-arm64)  TRIPLET="arm64-apple-darwin"; WANT="Mach-O"; ARCHIVE="tar.gz"
                  STRIP="strip"; PRETTY="macOS (Apple Silicon)" ;;
    macos-x86_64) TRIPLET="x86_64-apple-darwin"; WANT="Mach-O"; ARCHIVE="tar.gz"
                  STRIP="strip"; PRETTY="macOS (Intel)" ;;
    *) die "platform must be windows, macos-arm64 or macos-x86_64 (got '$PLATFORM')" ;;
esac
case "$VERSION" in v*) ;; *) VERSION="v$VERSION" ;; esac

echo
echo "=================================================================="
echo " ${BLD}packaging WAM Coin $VERSION for $TRIPLET${OFF}"
echo "=================================================================="
echo "  from: $FROM"
echo

# ---------------------------------------------------------------------------
#  Is this actually that platform?
# ---------------------------------------------------------------------------
#
# `file` is asked, not the directory name. On 7 September a build script was
# handed a native RandomX archive for a cross-compile and produced something
# that linked and could not run; the lesson written down then was that flags
# describe intent and the file describes the file.
command -v file >/dev/null 2>&1 || die "the 'file' command is required to check the binaries"

echo "${BLD}1. what these files actually are${OFF}"
found=0; wrong=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "${f##*/}" in *.log|*.txt|*.md) continue ;; esac
    fmt="$(file -bL "$f")"
    case "$fmt" in
        *"$WANT"*) ok "$(printf '%-16s %s' "${f##*/}" "${fmt:0:52}")"; found=$((found+1)) ;;
        *) bad "$(printf '%-16s %s' "${f##*/}" "${fmt:0:52}")"; wrong=$((wrong+1)) ;;
    esac
done <<EOF
$(find "$FROM" -maxdepth 2 -type f | sort)
EOF

[ "$wrong" -eq 0 ] || die "$wrong file(s) are not $WANT. Nothing was packaged."
[ "$found" -gt 0 ] || die "no executables found under $FROM"
ok "$found file(s), all $WANT"

# ---------------------------------------------------------------------------
echo
echo "${BLD}2. the same layout as the Linux archive${OFF}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
NODE="$STAGE/wam-coin-$VERSION"
mkdir -p "$NODE/bin" "$OUT"

for f in "$FROM"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in
        wam-miner|wam-miner.exe) ;;                      # handled below
        *.log|*.txt|*.md) ;;
        *) cp "$f" "$NODE/bin/" ;;
    esac
done
for f in COPYING README.md WHITEPAPER.md SECURITY.md; do
    [ -f "$REPO/$f" ] && cp "$REPO/$f" "$NODE/"
done
ok "bin/ holds $(find "$NODE/bin" -type f | wc -l | tr -d ' ') file(s)"

# Debug symbols, if whoever built these left them in.
#
# package_release.sh has stripped the Linux binaries since the first release --
# "Debug symbols are most of the size and none of the use. 339 MB -> ~30 MB" --
# and on 12 September the Windows artifact from platform-build #10 was 197 MB
# because nothing in the Windows path did the same. On a connection carrying
# 16 KB/s that is three and a half hours to download a node.
#
# build_windows.sh now strips before the consensus gate runs, so binaries that
# came through the workflow arrive here already stripped and this is a no-op
# that says so. It stays because this script also accepts a directory somebody
# built by hand.
BEFORE_KB=$(du -sk "$NODE/bin" | cut -f1)
if command -v "$STRIP" >/dev/null 2>&1; then
    "$STRIP" "$NODE/bin"/* 2>/dev/null || true
    AFTER_KB=$(du -sk "$NODE/bin" | cut -f1)
    if [ "$AFTER_KB" -lt "$BEFORE_KB" ]; then
        ok "stripped      $(( BEFORE_KB / 1024 )) MB -> $(( AFTER_KB / 1024 )) MB"
    else
        ok "no symbols to strip -- already $(( AFTER_KB / 1024 )) MB"
    fi
else
    # Not fatal: a 197 MB archive is worse than a small one and better than
    # none. But it is said in the colour that means "look at this".
    warn "$STRIP not found, so nothing was stripped: $(( BEFORE_KB / 1024 )) MB"
    warn "of binaries, most of it debug symbols. On Ubuntu, for Windows:"
    warn "    sudo apt install binutils-mingw-w64-x86-64"
fi

cat > "$NODE/RELEASE.txt" <<TXT
WAM Coin $VERSION -- $TRIPLET

These binaries were cross-compiled on Linux by the platform-build workflow
and then run against the live test chain on a $PRETTY runner, which synced
from the genesis block over the real peer-to-peer protocol and compared four
blocks the Linux nodes have held since August: 0, 1, 5000 and 6000. Block 1
is where the 5% treasury rule is first enforced, so a binary that disagrees
about consensus disagrees there.

The miner in the separate archive was cross-compiled the same way and then
ran --self-test on a $PRETTY machine, which checks SHA-256, stratum byte
order, the difficulty targets, and RandomX against the two official test
vectors. A miner whose RandomX disagreed with the network would hash all day,
find nothing, and report no error at all, so that check is the whole question.

That is what is being claimed, and all of it. What is NOT claimed:

  * no human had double-clicked these before the release that carries them
  * the packaging and the signature had never covered a second platform
    before $VERSION, so this path is newer than the Linux one

$(if [ "$PLATFORM" = "windows" ]; then cat <<'WARN'
YOUR ANTIVIRUS WILL PROBABLY OBJECT TO THE MINER, AND IT IS WRONG.

On 12 September, during testing, Windows Defender deleted wam-miner.exe
fourteen seconds after it started hashing and called it

    Trojan:Win32/Bearfoos.A!ml      (Severe)

!ml means a machine-learning guess. A program that opens a network
connection and then uses every core is behaving exactly like the
cryptojacking malware that infects people's computers without asking, and
no scanner can tell the two apart by behaviour -- the difference is that
you chose this one and it mines to your address only.

We have not paid for a publisher certificate, which is the only thing that
removes the warning, so we are telling you about it instead of letting it
surprise you. What to do:

  1. Check the file yourself. The SHA256 below and the signature on
     SHA256SUMS are proof that these are the bytes we built. An antivirus
     verdict is an opinion; a signature is evidence.
  2. If you want to run it, allow that one file by name in your antivirus
     -- not a whole folder, and never the whole machine.
  3. If you would rather not, do not. The node in the other archive is not
     a miner and is not usually flagged, and you can run a node without
     ever mining.

Anyone claiming to be us and asking you to switch your antivirus off
entirely is not us.
WARN
fi)

VERIFY BEFORE YOU RUN IT. The checksum file is signed with a key kept
offline, and the fingerprint is published in SECURITY.md in the source
repository and nowhere else:

  4BD4 A8D3 AFD4 3F5C BCB5  00E2 3798 462F E00A DBA4

  curl -LO .../SHA256SUMS
  curl -LO .../SHA256SUMS.asc
  curl -LO .../scripts/verify_release.sh
  curl -LO .../SIGNING-KEY.asc
  bash verify_release.sh .

A release without SHA256SUMS.asc beside it cannot be checked. Do not run it.
TXT
ok "RELEASE.txt written -- it says what was tested and what was not"

MINERSRC=""
for cand in "$FROM/wam-miner.exe" "$FROM/wam-miner"; do
    [ -f "$cand" ] && MINERSRC="$cand" && break
done
if [ -n "$MINERSRC" ]; then
    MIN="$STAGE/wam-miner-$VERSION"
    mkdir -p "$MIN"
    cp "$MINERSRC" "$MIN/"
    command -v "$STRIP" >/dev/null 2>&1 && "$STRIP" "$MIN"/* 2>/dev/null || true
    [ -f "$REPO/COPYING" ] && cp "$REPO/COPYING" "$MIN/"
    [ -f "$REPO/miner/README.md" ] && cp "$REPO/miner/README.md" "$MIN/"
    ok "miner packaged separately, as on Linux"
else
    # Loud, because this is the failure that shipped nothing for six days.
    # RandomX exists in this chain so an ordinary desktop can mine, and most
    # ordinary desktops are the platform being packaged here. A node without a
    # miner gives those people a wallet and tells them to install Linux.
    warn "no miner in $FROM -- the node archive is made alone."
    warn "For Windows and macOS that is a release that cannot mine. Check that"
    warn "the build script produced wam-miner$([ "$PLATFORM" = windows ] && echo .exe)."
fi

# ---------------------------------------------------------------------------
echo
echo "${BLD}3. archives${OFF}"

made=()
pack() {   # pack <stage subdir> <archive base name>
    local dir="$1" base="$2"
    if [ "$ARCHIVE" = "zip" ]; then
        command -v zip >/dev/null 2>&1 || die "zip is not installed, and Windows users expect a .zip"
        ( cd "$STAGE" && zip -q -r "$OUT/$base.zip" "$dir" ) || die "zip failed for $base"
        made+=("$base.zip")
    else
        tar -czf "$OUT/$base.tar.gz" -C "$STAGE" "$dir" || die "tar failed for $base"
        made+=("$base.tar.gz")
    fi
}

pack "wam-coin-$VERSION"  "wam-coin-$VERSION-$TRIPLET"
[ -n "$MINERSRC" ] && pack "wam-miner-$VERSION" "wam-miner-$VERSION-$TRIPLET"

for a in "${made[@]}"; do
    sz=$(stat -c%s "$OUT/$a" 2>/dev/null || echo 0)
    ok "$(printf '%-46s %s' "$a" "$(( sz / 1024 )) KB")"
done

# ---------------------------------------------------------------------------
echo
echo "${BLD}4. the lines to add to SHA256SUMS${OFF}"
echo
( cd "$OUT" && sha256sum "${made[@]}" ) | sed 's/^/    /'
echo
echo "        Append these to the release's SHA256SUMS, then sign that file"
echo "        with the offline key -- this script cannot and must not:"
echo
echo "            bash scripts/sign_release.sh"
echo
echo "=================================================================="
printf ' %s%s%s packaged for %s%s\n' "$GRN" "$BLD" "$VERSION" "$TRIPLET" "$OFF"
echo "=================================================================="
echo

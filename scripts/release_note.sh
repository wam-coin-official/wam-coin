#!/bin/bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  release_note.sh -- the RELEASE.txt inside a platform archive
# ===========================================================================
#
#      bash scripts/release_note.sh --platform windows     --version v0.1.8
#      bash scripts/release_note.sh --platform macos-arm64 --version v0.1.8
#
#  It prints the note and nothing else, so it can be read by a test.
#
#  WHY IT IS ITS OWN FILE
#
#  This text used to live inside package_platform.sh, and on 12 September it
#  was wrong four times in one evening -- each time differently, each time
#  found by unpacking a finished artifact and reading it, and each time
#  costing a full workflow run:
#
#    1. empty on macOS. It was a heredoc nested inside a command substitution
#       nested inside another heredoc; bash 5 built it and bash 3.2, which is
#       what macOS ships, produced nothing. The script printed "ok ... written"
#       about a file of zero bytes.
#    2. then the script would not parse at all on macOS, because the fix put a
#       heredoc inside $( ), which bash 3.2 also cannot read. That exited 2
#       before doing anything, which was at least honest.
#    3. then it told Mac owners "These binaries were cross-compiled on Linux",
#       which is true of Windows and false of macOS: the macOS build is
#       native. The paragraph had been written for one platform and reused for
#       all of them.
#    4. and the test written to catch (3) failed on the corrected text,
#       because it grepped for the word "cross-compiled" and the correction
#       says "not cross-compiled from anything".
#
#  The root of all four is one thing, and it is not any of the four. The
#  packaging script is parameterised by platform and I exercised exactly one
#  branch of it -- on Linux, in WSL -- and then shipped it to a macOS runner.
#  Every one of those faults is something a Linux run cannot reveal.
#
#  So the note is separated from the packaging. It needs no binaries, no
#  archive and no runner: a platform name and a version are enough, which
#  means scripts/test/test_release_note.sh can exercise EVERY platform this
#  project supports, in a second, before anything is pushed. That is the fix.
#  The four above were repairs.
#
#  WHAT BELONGS HERE AND WHAT DOES NOT
#
#  Only claims that are true of the archive being built, stated so that a
#  stranger can check them. Anything this project has not measured belongs in
#  the "what is NOT claimed" list instead, and that list is the reason the file
#  exists: a release note that only boasts is an advertisement.
# ===========================================================================

set -uo pipefail

PLATFORM=""; VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORM="${2:-}"; shift 2 ;;
        --version)  VERSION="${2:-}";  shift 2 ;;
        -h|--help)  sed -n '5,50p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[ -n "$PLATFORM" ] && [ -n "$VERSION" ] || {
    printf 'usage: %s --platform PLATFORM --version vX.Y.Z\n' "${0##*/}" >&2
    exit 2; }
case "$VERSION" in v*) ;; *) VERSION="v$VERSION" ;; esac

# How the binaries in this archive were actually produced, and where the
# miner's self-test ran. Facts about the platform, kept beside the platform,
# so that adding one cannot leave the prose describing a different one.
# Whole paragraphs, wrapped here, rather than fragments interpolated into the
# middle of a sentence. The fragment form put an 83-column line in the note --
# "was compiled on that same machine, so it ran its" and then a break before
# "own --self-test" -- because where a fragment ends is not where a line
# should break. It also made the text impossible to check with one grep, which
# is how the test written for it failed on the corrected version.
case "$PLATFORM" in
    windows)
        TRIPLET="x86_64-w64-mingw32"
        PRETTY="Windows"
        BUILT_PARA="These binaries were cross-compiled on Linux by the
platform-build workflow."
        MINER_PARA="The miner in the separate archive was cross-compiled the
same way. Linux cannot run it, so --self-test was run on a Windows machine
afterwards."
        ;;
    macos-arm64)
        TRIPLET="arm64-apple-darwin"
        PRETTY="macOS (Apple Silicon)"
        BUILT_PARA="These binaries were compiled natively, on a macOS runner,
by the platform-build workflow. Nothing here was cross-compiled."
        MINER_PARA="The miner in the separate archive was compiled on that
same machine, so it ran --self-test there during the build rather than on
another one afterwards."
        ;;
    macos-x86_64)
        TRIPLET="x86_64-apple-darwin"
        PRETTY="macOS (Intel)"
        BUILT_PARA="These binaries were compiled natively, on a macOS runner,
by the platform-build workflow. Nothing here was cross-compiled."
        MINER_PARA="The miner in the separate archive was compiled on that
same machine, so it ran --self-test there during the build rather than on
another one afterwards."
        ;;
    *)
        printf 'release_note.sh: unknown platform: %s\n' "$PLATFORM" >&2
        exit 2 ;;
esac

# Three plain heredocs, appended in order, none of them nested and none inside
# a command substitution. That is the whole of the portability requirement and
# it is why this is written the long way round -- see (1) and (2) above.
cat <<TXT
WAM Coin $VERSION -- $TRIPLET

$BUILT_PARA

They were then run against the live test chain on a $PRETTY machine, which
synced from the genesis block over the real peer-to-peer protocol and
compared four blocks the Linux nodes have held since August: 0, 1, 5000 and
6000. Block 1 is where the 5% treasury rule is first enforced, so a binary
that disagrees about consensus disagrees there.

The chain was synced with the files in THIS archive, after stripping and
packaging, not with an earlier build of them.

$MINER_PARA

That check covers SHA-256, stratum byte order, the difficulty targets, and
RandomX against the two official test vectors. A miner whose RandomX
disagreed with the network would hash all day, find nothing, and report no
error at all, so it is the whole question.

That is what is being claimed, and all of it. What is NOT claimed:

  * no human had double-clicked these before the release that carries them
  * before $VERSION the packaging and the signature covered Linux and
    nothing else, so this path is newer and less worn than that one
TXT

if [ "$PLATFORM" = "windows" ]; then
    cat <<'WARN'

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
fi

cat <<'TXT'

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

#!/bin/bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  test_release_note.sh -- every platform's release note, checked here
# ===========================================================================
#
#      bash scripts/test/test_release_note.sh
#
#  WHY
#
#  On 12 September the RELEASE.txt inside a platform archive was wrong four
#  times in one evening. Each fault was different, each was found by
#  downloading a finished artifact and reading the file, and each cost a
#  workflow run:
#
#    1. empty on macOS -- a heredoc nested inside a command substitution
#       nested inside another heredoc, which bash 5 builds and the bash 3.2
#       that macOS ships does not
#    2. then the script would not parse on macOS at all
#    3. then it told Mac owners their binaries were cross-compiled on Linux,
#       which is true of Windows and false of macOS
#    4. and the check written for (3) failed on the corrected text
#
#  The root was none of those. The packaging is parameterised by platform and
#  exactly one branch of it was ever exercised -- on Linux, in WSL -- and then
#  shipped to a macOS runner. Every one of those faults is invisible to a
#  Linux run.
#
#  So the note became its own script, which needs no binaries, no archive and
#  no runner: a platform name and a version. This exercises all three
#  platforms in about a second, and the sweep runs it. Nothing here needs a
#  Mac to find a fault that only shows on a Mac.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
NOTE="$HERE/scripts/release_note.sh"

GRN=$'\033[32m'; RED=$'\033[31m'; BLD=$'\033[1m'; OFF=$'\033[0m'
pass=0; fail=0
ok()  { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$*"; fail=$((fail+1)); }

printf '\n%severy platform gets a note that is true of it%s\n' "$BLD" "$OFF"

[ -f "$NOTE" ] || { bad "$NOTE is missing -- nothing was checked"; echo; exit 2; }

V=v9.9.9

for plat in windows macos-arm64 macos-x86_64; do
    out="$(bash "$NOTE" --platform "$plat" --version "$V" 2>&1)" || {
        bad "$plat: the script exited non-zero"; continue; }

    n=$(printf '%s' "$out" | wc -c | tr -d ' ')
    if [ "$n" -lt 1500 ]; then
        bad "$plat: $n bytes, which is not a release note"
        continue
    fi

    # The version has to appear, or the archive and its note disagree.
    printf '%s' "$out" | grep -q "$V" \
        && ok "$plat: names $V" \
        || bad "$plat: does not mention $V"

    # The triplet the archive is named for.
    case "$plat" in
        windows)      want=x86_64-w64-mingw32 ;;
        macos-arm64)  want=arm64-apple-darwin ;;
        macos-x86_64) want=x86_64-apple-darwin ;;
    esac
    printf '%s' "$out" | grep -q "$want" \
        && ok "$plat: names the triplet $want" \
        || bad "$plat: does not name $want"

    # Fault 3, the one that would have shipped: only Windows is
    # cross-compiled. Matched on the CLAIM, not on the word, because the
    # macOS text legitimately contains "not cross-compiled from anything" --
    # which is what fault 4 was.
    if printf '%s' "$out" | grep -q "were cross-compiled on Linux"; then
        [ "$plat" = "windows" ] \
            && ok "$plat: says cross-compiled, which is true of it" \
            || bad "$plat: claims it was cross-compiled on Linux, and it was not"
    else
        [ "$plat" = "windows" ] \
            && bad "windows: does not say it was cross-compiled, and it was" \
            || ok "$plat: does not claim cross-compilation"
    fi

    # Where the miner's self-test ran differs, and saying the wrong one is a
    # claim about the chain of custody.
    if [ "$plat" = "windows" ]; then
        printf '%s' "$out" | grep -q "so --self-test was run on a Windows machine" \
            && ok "$plat: the self-test is placed after the build, on Windows" \
            || bad "$plat: does not say where the miner tested itself"
    else
        printf '%s' "$out" | grep -q "ran --self-test there during the build" \
            && ok "$plat: the self-test is placed during the build" \
            || bad "$plat: does not say where the miner tested itself"
    fi

    # The antivirus section belongs to Windows and to nothing else. On macOS
    # it would be a warning about a program the reader is not running.
    if printf '%s' "$out" | grep -q "YOUR ANTIVIRUS"; then
        [ "$plat" = "windows" ] \
            && ok "$plat: carries the Defender warning" \
            || bad "$plat: carries a Windows antivirus warning"
    else
        [ "$plat" = "windows" ] \
            && bad "windows: no Defender warning, and it is the platform that needs it" \
            || ok "$plat: no Windows warning, correctly"
    fi

    # The fingerprint is the only thing a reader can anchor on.
    printf '%s' "$out" | grep -q "4BD4 A8D3 AFD4 3F5C BCB5  00E2 3798 462F E00A DBA4" \
        && ok "$plat: carries the published fingerprint" \
        || bad "$plat: does not carry the fingerprint"

    # And it must still say what it does NOT claim. A note that only boasts
    # is an advertisement, and that list is the reason the file exists.
    printf '%s' "$out" | grep -q "What is NOT claimed" \
        && ok "$plat: still says what is not being claimed" \
        || bad "$plat: dropped the 'what is NOT claimed' list"
done

# An unknown platform must be refused, not guessed at.
if bash "$NOTE" --platform freebsd --version "$V" >/dev/null 2>&1; then
    bad "an unknown platform produced a note instead of an error"
else
    ok "an unknown platform is refused"
fi

echo
if [ "$fail" -gt 0 ]; then
    printf ' %s%d of %d checks failed%s\n\n' "$RED" "$fail" "$((pass+fail))" "$OFF"
    exit 1
fi
printf ' %s%s%d checks, three platforms, none of them needing that platform%s\n\n' \
    "$GRN" "$BLD" "$pass" "$OFF"

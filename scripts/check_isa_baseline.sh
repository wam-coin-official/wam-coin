#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_isa_baseline.sh -- will this binary run on the CPU someone has?
# ===========================================================================
#
#      bash scripts/check_isa_baseline.sh FILE [FILE...]
#      bash scripts/check_isa_baseline.sh out/release/wam-coin-*/bin/*
#
#  WHY THIS EXISTS
#
#  The v0.1.2 release was built by GitHub Actions, verified by the release
#  workflow, downloaded, checksum-matched, and started on a server -- where it
#  ran for ten minutes and then:
#
#      wamd.service: Main process exited, code=dumped, status=4/ILL
#
#  SIGILL. The binary carried 746 AVX-512 instructions, because RandomX was
#  built with ARCH=native and the node links it statically, so the node
#  inherited the instruction set of GitHub's runner. The machine it was sent
#  to is an AMD EPYC without AVX-512, which is most server CPUs before Genoa
#  and every consumer Intel before Ice Lake.
#
#  The release pipeline already tried to prevent this. It checked that the
#  node's own CXXFLAGS carried no -march=, which was true and beside the
#  point: the instructions came in through a linked library. It rebuilt
#  RandomX portably -- and gave that copy to the miner, not the node. Both
#  checks passed. The artifact crashed.
#
#  So this reads the shipped file. Not the flags that were meant to build it,
#  not the library it was meant to link: the instructions actually in it.
#
#  WHY AVX-512 IS THE LINE
#
#  AVX2 appears in every one of these binaries and always has, behind runtime
#  dispatch in libstdc++ and in Core's own SHA-NI selection -- code that asks
#  the CPU before it jumps. AVX-512 has never appeared in a working build and
#  appeared in exactly the one that crashed, from a library compiled to assume
#  it unconditionally. That is a line with a fact behind it rather than a
#  preference, which is the only kind worth failing a release over.
# ===========================================================================

set -uo pipefail

[ $# -ge 1 ] || {
    printf 'reason: no file was given\n'
    printf 'usage: %s FILE [FILE...]\n' "${0##*/}" >&2; exit 2; }

# The disassembler is named once. This script used to print
# "OBJDUMP=llvm-objdump (or run this on the machine that built it)" as the
# way to read a Mach-O binary, and then call `objdump` regardless -- advice
# that could be followed exactly and change nothing. If it tells you which
# tool to use, it has to be the tool it uses.
OBJDUMP="${OBJDUMP:-objdump}"
command -v "$OBJDUMP" >/dev/null 2>&1 || {
    printf 'reason: %s is not installed (apt-get install -y binutils)\n' "$OBJDUMP"
    printf '%s is required: apt-get install -y binutils\n' "$OBJDUMP" >&2; exit 2; }

# `file` decides which format each argument is, and a missing `file` used to
# mean every argument fell through the case below as "unknown" and was
# skipped in silence. On 12 September the Singapore seed had no `file`: this
# script examined nothing, said so, and exited 1 -- and its caller printed
# "the published binaries carry instructions many CPUs do not have" in red
# about a release whose five Linux binaries are clean. One absent 100 KB
# utility became a launch-stopping claim.
#
# Reading the magic bytes with od would remove the dependency altogether and
# is the better fix; three days before launch, this one says so instead.
command -v file >/dev/null 2>&1 || {
    printf 'reason: file(1) is not installed, so no format could be identified (apt-get install -y file)\n'
    printf 'file is required: apt-get install -y file\n' >&2; exit 2; }

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; OFF=$'\033[0m'
FAIL=0
CHECKED=0
ARM=0
UNREADABLE=0

echo "=================================================================="
echo " Instructions above the x86-64 baseline"
echo "=================================================================="
echo

printf '  %-16s %-10s %-10s %s\n' "file" "AVX-512" "AVX2" "verdict"
printf '  %s\n' "--------------------------------------------------------------"

for f in "$@"; do
    [ -f "$f" ] || continue

    # Every executable format this project can ship, not only ELF.
    #
    # This line used to be `grep -q 'ELF...' || continue`, and that was written
    # when the only release was Linux. The moment a Windows or macOS binary
    # joins a release, a silent `continue` removes the one guard that exists
    # because a published node died with SIGILL on an AMD EPYC -- and removes
    # it for the audience most likely to be running an old processor. A skip
    # that reads as a pass is the exact shape of the fault it was written to
    # prevent.
    # -L follows symlinks. Without it `file` answers "symbolic link to ..."
    # and the case below skips it -- so pointing this at an installed path,
    # which is the obvious thing an operator does, reported "nothing was
    # examined" for a binary sitting right there. /opt/wam-current-bin/wamd
    # is a symlink on both servers.
    DESC="$(file -bL "$f" 2>/dev/null || echo unknown)"
    case "$DESC" in
        *ELF*executable*|*ELF*shared\ object*|*"for MS Windows"*|*PE32*|*Mach-O*) ;;
        *) continue ;;                 # scripts, tarballs, text: not our subject
    esac

    # arm64 is not an x86-64 question at all. Apple Silicon is the majority of
    # Macs sold since 2020, so this will be a real row rather than a
    # hypothetical one, and it must be visible: reporting an arm64 binary as
    # "within the x86-64 baseline" would be a confident answer to a question
    # nobody asked.
    case "$DESC" in
        *arm64*|*aarch64*|*"ARM64"*)
            printf '  %-16s %-10s %-10s %sarm64 -- this check does not apply%s\n' \
                "$(basename "$f")" "-" "-" "$YLW" "$OFF"
            ARM=$((ARM + 1))
            continue ;;
    esac

    CHECKED=$((CHECKED + 1))

    D="$("$OBJDUMP" -d --no-show-raw-insn "$f" 2>/dev/null)"
    if [ -z "$D" ]; then
        # Not `continue`. CHECKED has already been incremented, so continuing
        # here counted an unreadable file towards "all N binaries stay within
        # the baseline" -- a pass issued for a binary that was never read.
        # True of a stripped ELF as much as of a Mach-O that GNU objdump
        # cannot open.
        printf '  %-16s %s%s%s\n' "$(basename "$f")" \
            "$RED" "could not disassemble -- NOT examined" "$OFF"
        UNREADABLE=$((UNREADABLE + 1))
        CHECKED=$((CHECKED - 1))
        continue
    fi

    # zmm registers and the k mask registers are unambiguous: nothing below
    # AVX-512 can name them.
    A512="$(printf '%s' "$D" | grep -cE '%zmm[0-9]+|\{%k[0-7]\}|vpternlog|vpcompress|vpexpand|\bkmov[bwdq]?\b')"
    A2="$(printf '%s' "$D" | grep -cE '%ymm[0-9]+')"

    if [ "$A512" -gt 0 ]; then
        printf '  %-16s %s%-10s%s %-10s %sWILL CRASH on a CPU without AVX-512%s\n' \
            "$(basename "$f")" "$RED" "$A512" "$OFF" "$A2" "$RED" "$OFF"
        printf '%s' "$D" | grep -nE '%zmm[0-9]+|vpternlog|\bkmov' | head -2 \
            | sed 's/^/                   /'
        FAIL=$((FAIL + 1))
    else
        printf '  %-16s %s%-10s%s %-10s runs on any x86-64\n' \
            "$(basename "$f")" "$GRN" "0" "$OFF" "$A2"
    fi
done

echo
echo "=================================================================="
if [ "$UNREADABLE" -gt 0 ]; then
    printf 'reason: %d binary(ies) could not be disassembled by %s\n' \
        "$UNREADABLE" "$OBJDUMP"
    printf ' %s%d binary(ies) could not be disassembled -- this check did not run%s\n' \
        "$RED" "$UNREADABLE" "$OFF"
    echo
    echo ' A pass cannot be issued for a file that was not read. GNU objdump'
    echo ' cannot open Mach-O; use the LLVM one on a macOS runner:'
    echo '     OBJDUMP=llvm-objdump  (or run this on the machine that built it)'
    echo "=================================================================="
    exit 2
fi
if [ "$CHECKED" -eq 0 ] && [ "$ARM" -eq 0 ]; then
    # This exited 1, which every caller reads as "AVX-512 was found". It is
    # the opposite: nothing was opened, so nothing is known. The two are
    # indistinguishable in a summary and only one of them should stop a
    # release -- and the difference cost a FAIL on 12 September, when a
    # caller globbed a path that matched no file and this script told it the
    # published binaries were unrunnable.
    printf 'reason: no file matched, so no binary was examined\n'
    printf ' %sno binary was examined -- this proves nothing%s\n' "$RED" "$OFF"
    echo "=================================================================="
    exit 2
fi
if [ "$CHECKED" -eq 0 ]; then
    printf 'reason: %d arm64 binary(ies) only, and this check is about x86-64\n' "$ARM"
    printf ' %s%d arm64 binary(ies) only -- nothing here was in this check'"'"'s scope%s\n' \
        "$YLW" "$ARM" "$OFF"
    echo
    echo ' The x86-64 baseline says nothing about Apple Silicon. That question'
    echo ' is real and is not this script: it needs its own floor.'
    echo "=================================================================="
    exit 2
fi
if [ "$FAIL" -eq 0 ]; then
    printf ' %sall %d x86-64 binaries stay within the baseline%s\n' "$GRN" "$CHECKED" "$OFF"
    [ "$ARM" -gt 0 ] && printf ' %s%d arm64 binary(ies) were not examined by this check%s\n' \
        "$YLW" "$ARM" "$OFF"
else
    printf ' %s%d of %d carry AVX-512 -- do not publish%s\n' "$RED" "$FAIL" "$CHECKED" "$OFF"
    echo
    echo ' RandomX was almost certainly built with ARCH=native. Rebuild it with'
    echo ' ARCH=x86-64 and relink the node; see scripts/fetch-upstream.sh.'
fi
echo "=================================================================="
[ "$FAIL" -eq 0 ]

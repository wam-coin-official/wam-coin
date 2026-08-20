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

[ $# -ge 1 ] || { printf 'usage: %s FILE [FILE...]\n' "${0##*/}" >&2; exit 2; }

command -v objdump >/dev/null 2>&1 || {
    printf 'objdump is required: apt-get install -y binutils\n' >&2; exit 3; }

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; OFF=$'\033[0m'
FAIL=0
CHECKED=0

echo "=================================================================="
echo " Instructions above the x86-64 baseline"
echo "=================================================================="
echo

printf '  %-16s %-10s %-10s %s\n' "file" "AVX-512" "AVX2" "verdict"
printf '  %s\n' "--------------------------------------------------------------"

for f in "$@"; do
    [ -f "$f" ] || continue
    file "$f" 2>/dev/null | grep -q 'ELF.*executable\|ELF.*shared object' || continue
    CHECKED=$((CHECKED + 1))

    D="$(objdump -d --no-show-raw-insn "$f" 2>/dev/null)"
    if [ -z "$D" ]; then
        printf '  %-16s %s\n' "$(basename "$f")" "could not disassemble"
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
if [ "$CHECKED" -eq 0 ]; then
    printf ' %sno ELF binary was examined -- this proves nothing%s\n' "$RED" "$OFF"
    echo "=================================================================="
    exit 1
fi
if [ "$FAIL" -eq 0 ]; then
    printf ' %sall %d binaries stay within the baseline%s\n' "$GRN" "$CHECKED" "$OFF"
else
    printf ' %s%d of %d carry AVX-512 -- do not publish%s\n' "$RED" "$FAIL" "$CHECKED" "$OFF"
    echo
    echo ' RandomX was almost certainly built with ARCH=native. Rebuild it with'
    echo ' ARCH=x86-64 and relink the node; see scripts/fetch-upstream.sh.'
fi
echo "=================================================================="
[ "$FAIL" -eq 0 ]

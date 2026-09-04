#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_release_matches.sh -- is the published download this network?
# ===========================================================================
#
#      bash scripts/check_release_matches.sh            # inspect the binary
#      bash scripts/check_release_matches.sh --source   # tag source only
#
#  WHY THIS EXISTS
#
#  v0.1.0 was tagged and published on 2026-08-15. Over the three days after
#  that, the founder reserve was locked, all three genesis blocks were
#  re-mined, and the treasury was given its own address. The published tarball
#  was never rebuilt. It stayed on the download page describing a different
#  network:
#
#      published mainnet genesis  bbbd737e...    source  d8d3debe...
#      published testnet genesis  b6668514...    source  ce81c20a...
#      published regtest genesis  1fa171c2...    source  b88f3d26...
#
#  A node from that tarball cannot connect to this network at all -- not a
#  version disagreement, a different chain. Someone downloaded it and mined
#  2,208 blocks on a history nobody else shares before anyone noticed.
#
#  WHAT IT CHECKS, AND WHY THAT WAY
#
#  Not the tag. The tag says what someone intended to build; it cannot say
#  what the artifact actually contains, and today's whole lesson is that those
#  differ. So this downloads the published binary and looks inside it for the
#  genesis hashes and treasury addresses that chainparams.cpp declares right
#  now. Those constants appear verbatim in the binary's read-only data, so
#  finding them needs no execution of a downloaded file.
#
#  --source additionally diffs the tagged tree against HEAD, which explains a
#  failure but can never substitute for looking at the artifact.
# ===========================================================================

set -uo pipefail

# An interpreter that is actually Python: `python3` on Windows is a
# Microsoft Store stub that runs nothing and exits 49.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPTS_DIR/lib/python.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
CHAINPARAMS="src/wam/chainparams.cpp"
REPO="wam-coin-official/wam-coin"
ALSO_SOURCE=0

case "${1:-}" in
    --source) ALSO_SOURCE=1 ;;
    "") ;;
    *) printf 'usage: %s [--source]\n' "${0##*/}" >&2; exit 2 ;;
esac

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
FAIL=0
# Set when something could not be measured at all. It is deliberately separate
# from FAIL: "I could not look" and "I looked and it is wrong" are different
# answers, and a summary that shows them the same way teaches people to ignore
# both. Exit 2 is this project's word for the first one.
COULD_NOT_CHECK=0
ok()   { printf '  %sok%s     %s\n' "$GRN" "$OFF" "$*"; }
bad()  { printf '  %sFAIL%s   %s\n' "$RED" "$OFF" "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  %swarn%s   %s\n' "$YLW" "$OFF" "$*"; }

command -v curl >/dev/null 2>&1 || { echo 'curl is required' >&2; exit 3; }

echo "=================================================================="
echo " Does the published download match this source?"
echo "=================================================================="

# ---------------------------------------------------------------------------
# What this source says the chains are. Read from the file, never repeated
# here, so a re-mine cannot leave this script asserting a stale value.
# ---------------------------------------------------------------------------
mapfile -t WANT_GENESIS < <(
    grep -oE 'hashGenesisBlock == uint256S\("0x[0-9a-f]{64}"\)' "$CHAINPARAMS" 2>/dev/null \
        | grep -oE '[0-9a-f]{64}'
)
mapfile -t WANT_ADDR < <(
    grep -oE 'WAM_(TREASURY|FOUNDER)_ADDRESS_(MAINNET|TESTNET) = "[A-Za-z0-9]+"' "$CHAINPARAMS" 2>/dev/null \
        | grep -oE '"[A-Za-z0-9]+"' | tr -d '"'
)

if [ "${#WANT_GENESIS[@]}" -eq 0 ]; then
    bad "could not read a single genesis hash out of $CHAINPARAMS"
    echo; echo " Nothing was compared."; exit 1
fi
printf '\n%swhat this source declares%s\n' "$BLD" "$OFF"
for g in "${WANT_GENESIS[@]}"; do printf '    genesis  %s\n' "$g"; done
for a in "${WANT_ADDR[@]}"; do printf '    address  %s\n' "$a"; done

# ---------------------------------------------------------------------------
printf '\n%sthe published release%s\n' "$BLD" "$OFF"

API="$(curl -sSL -m 40 "https://api.github.com/repos/$REPO/releases?per_page=10" 2>/dev/null)"
if [ -z "$API" ]; then
    bad "could not reach the GitHub API -- the published artifact was NOT checked"
    echo; echo "=================================================================="
    exit 1
fi

read -r TAG URL < <(printf '%s' "$API" | "$PY" -c "
import sys; sys.stdout.reconfigure(newline='\n')  # no \r on Windows
import json, sys
try:
    rs = json.load(sys.stdin)
except Exception:
    sys.exit()
if isinstance(rs, dict) or not rs:
    sys.exit()
for r in rs:
    if r.get('draft'):
        continue
    for a in r.get('assets', []):
        n = a.get('name', '')
        if n.startswith('wam-coin') and n.endswith('.tar.gz'):
            print(r.get('tag_name'), a.get('browser_download_url'))
            sys.exit()
" 2>/dev/null)

if [ -z "${URL:-}" ]; then
    warn "no published release carries a wam-coin tarball -- nothing to contradict"
    echo; echo "=================================================================="
    [ "$FAIL" -eq 0 ]; exit
fi
printf '    %s\n    %s\n' "$TAG" "$URL"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! curl -sSL -m 300 -o "$TMP/r.tar.gz" "$URL" 2>/dev/null; then
    bad "could not download the published tarball -- it was NOT checked"
    echo; echo "=================================================================="
    exit 1
fi
tar -xzf "$TMP/r.tar.gz" -C "$TMP" 2>/dev/null
BIN="$(find "$TMP" -type f -name 'wamd' | head -1)"
if [ -z "$BIN" ]; then
    bad "the published tarball contains no wamd"
    echo; echo "=================================================================="
    exit 1
fi
printf '    unpacked %s (%s bytes)\n' "${BIN#$TMP/}" "$(stat -c%s "$BIN")"

# ---------------------------------------------------------------------------
printf '\n%sdoes it carry this network?%s\n' "$BLD" "$OFF"

STR="$TMP/strings.txt"
strings -n 24 "$BIN" > "$STR" 2>/dev/null || tr -cd '\11\12\15\40-\176' < "$BIN" > "$STR"

MISSING_G=0
for g in "${WANT_GENESIS[@]}"; do
    if grep -qF "$g" "$STR"; then
        ok "carries genesis ${g:0:16}..."
    else
        bad "does NOT carry genesis ${g:0:16}... -- a node from this download
           is on a different chain and can never connect"
        MISSING_G=$((MISSING_G + 1))
    fi
done

for a in "${WANT_ADDR[@]}"; do
    if grep -qF "$a" "$STR"; then
        ok "carries address $a"
    else
        bad "does NOT carry $a -- it enforces a different consensus payout"
    fi
done

# ---------------------------------------------------------------------------
# Carrying the right chain is not the same as running at all. v0.1.2 carried
# every correct constant and died with SIGILL on the first CPU without AVX-512,
# because the node links a RandomX that had been built with ARCH=native on the
# machine that produced the release. The tarball is already unpacked here, so
# the question costs nothing to ask.
printf '\n%swill it run on the CPU someone has?%s\n' "$BLD" "$OFF"
bash "$HERE/scripts/check_isa_baseline.sh" "$(dirname "$BIN")"/* >"$TMP/isa.log" 2>&1
ISA_RC=$?
if [ "$ISA_RC" -eq 0 ]; then
    ok "no instruction above the x86-64 baseline"
elif [ "$ISA_RC" -eq 2 ] || [ "$ISA_RC" -eq 3 ]; then
    # 3 is check_isa_baseline.sh saying objdump is not installed; 2 is its
    # usage error. Neither is a finding about the binaries.
    #
    # This branch did not exist, and every non-zero exit was reported as
    # "the published binaries carry instructions many CPUs do not have" --
    # a specific, alarming claim about something never examined. On Windows,
    # where objdump is absent, it fired on every run. Asked on a machine that
    # has objdump, the real answer is that all five binaries stay inside the
    # baseline with zero AVX-512.
    #
    # This project already has a word for this: exit 2 means the check could
    # not run, and sweep.sh prints it as "could not check" rather than as a
    # failure. The distinction exists because a fault that cannot be measured
    # and a fault that was measured look identical in a summary, and only one
    # of them is a reason to stop.
    warn "the CPU baseline was NOT checked: $(head -1 "$TMP/isa.log")"
    COULD_NOT_CHECK=1
else
    sed -n '/^  [a-z]/p' "$TMP/isa.log" | sed 's/^/         /'
    bad "the published binaries carry instructions many CPUs do not have"
fi

# ---------------------------------------------------------------------------
if [ "$ALSO_SOURCE" -eq 1 ] && [ -n "${TAG:-}" ]; then
    printf '\n%swhat changed since the tag%s\n' "$BLD" "$OFF"
    if git rev-parse -q --verify "$TAG^{commit}" >/dev/null 2>&1; then
        N="$(git log --oneline "$TAG..HEAD" -- src/ 2>/dev/null | wc -l)"
        if [ "$N" -eq 0 ]; then
            ok "no commit has touched src/ since $TAG"
        else
            bad "$N commit(s) changed src/ since $TAG:"
            git log --oneline "$TAG..HEAD" -- src/ 2>/dev/null | sed 's/^/           /'
        fi
    else
        warn "$TAG is not a commit in this clone -- fetch tags to compare"
    fi
fi

echo
echo "=================================================================="
if [ "$FAIL" -ne 0 ]; then
    printf ' %sthe published download is NOT this network%s\n' "$RED" "$OFF"
    echo
    echo ' Anyone who downloads it gets a node that cannot join. Rebuild and'
    echo ' republish from current source before telling anyone to download it.'
    echo "=================================================================="
    exit 1
fi
if [ "$COULD_NOT_CHECK" -ne 0 ]; then
    printf ' %severything asked matched -- but not everything could be asked%s\n' "$YLW" "$OFF"
    echo
    echo ' The lines marked warn above were not measured. They are not passes.'
    echo "=================================================================="
    exit 2
fi
printf ' %sthe published download is this network%s\n' "$GRN" "$OFF"
echo "=================================================================="
exit 0

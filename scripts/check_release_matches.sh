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

command -v curl >/dev/null 2>&1 || { echo 'curl is required' >&2; exit 2; }

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

# Every published wam-coin archive, not the first one alphabetically.
#
# This used to read one asset: the first whose name starts with wam-coin and
# ends in .tar.gz. That was the Linux tarball for as long as Linux was the
# only platform. On 12 September macOS joined the release and sorts ahead of
# it, so the single artifact this script examined became the arm64 Mac build
# -- and the Linux tarball that every seed and every Linux miner downloads
# stopped being examined at all, silently, by the script whose whole purpose
# is to ask whether the published download is this network.
#
# The order is deliberate: linux, then windows, then macOS, so that a link
# which dies halfway has already answered the question for the platform the
# servers run.
mapfile -t ASSETS < <(printf '%s' "$API" | "$PY" -c "
import sys; sys.stdout.reconfigure(newline='\n')  # no \r on Windows
import json, sys
try:
    rs = json.load(sys.stdin)
except Exception:
    sys.exit()
if isinstance(rs, dict) or not rs:
    sys.exit()
def rank(n):
    for i, k in enumerate(('linux', 'mingw', 'w64', 'darwin')):
        if k in n:
            return i
    return 9
for r in rs:
    if r.get('draft'):
        continue
    out = []
    for a in r.get('assets', []):
        n = a.get('name', '')
        if n.startswith('wam-coin') and (n.endswith('.tar.gz') or n.endswith('.zip')):
            out.append((rank(n), n, a.get('browser_download_url'), r.get('tag_name')))
    if out:
        for _, n, u, t in sorted(out):
            print(t, n, u)
        sys.exit()
" 2>/dev/null)

if [ "${#ASSETS[@]}" -eq 0 ]; then
    warn "no published release carries a wam-coin archive -- nothing to contradict"
    echo; echo "=================================================================="
    [ "$FAIL" -eq 0 ]; exit
fi
TAG="${ASSETS[0]%% *}"
printf '    %s, %d published archive(s)\n' "$TAG" "${#ASSETS[@]}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# One artifact: download it, unpack it, and ask it the two questions -- does
# it carry this network, and will it start on an ordinary CPU.
# ---------------------------------------------------------------------------
check_artifact() {
    local name="$1" url="$2"
    local d="$TMP/$name" bin got str isa_rc isa_reason isa_remote h
    mkdir -p "$d"
    printf '\n%s%s%s\n' "$BLD" "$name" "$OFF"

    if ! curl -sSL -m 300 -o "$d/$name" "$url" 2>/dev/null; then
        # Not a finding. This file argues the distinction itself further down:
        # exit 2 means the check could not run, and a fault that cannot be
        # measured must not look like a fault that was measured.
        #
        # A download that times out says nothing about the release. On
        # 11 September this went red on a link carrying 16 KB/s -- 963 KB of
        # an 11.7 MB tarball in sixty seconds -- and reported it as though the
        # published download were wrong. A red that appears every time because
        # of somebody's connection is a red that stops being read.
        got="$(wc -c < "$d/$name" 2>/dev/null || echo 0)"
        warn "NOT downloaded: $got byte(s) in 300s -- that is this connection,
           not the release. Run this check from one of the servers, or accept
           that it was not measured here."
        COULD_NOT_CHECK=1
        return 0
    fi

    case "$name" in
        *.tar.gz)
            tar -xzf "$d/$name" -C "$d" 2>/dev/null ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -qo "$d/$name" -d "$d" 2>/dev/null
            else
                warn "NOT unpacked: unzip is not installed here, so the Windows
           archive was not examined"
                COULD_NOT_CHECK=1
                return 0
            fi ;;
    esac

    bin="$(find "$d" -type f \( -name 'wamd' -o -name 'wamd.exe' \) | head -1)"
    if [ -z "$bin" ]; then
        bad "$name contains no wamd"
        return 0
    fi
    printf '    unpacked %s (%s bytes)\n' "${bin#"$d"/}" "$(stat -c%s "$bin")"

    str="$d/strings.txt"
    strings -n 24 "$bin" > "$str" 2>/dev/null || tr -cd '\11\12\15\40-\176' < "$bin" > "$str"

    for g in "${WANT_GENESIS[@]}"; do
        if grep -qF "$g" "$str"; then
            ok "carries genesis ${g:0:16}..."
        else
            bad "does NOT carry genesis ${g:0:16}... -- a node from this download
           is on a different chain and can never connect"
        fi
    done
    for a in "${WANT_ADDR[@]}"; do
        if grep -qF "$a" "$str"; then
            ok "carries address $a"
        else
            bad "does NOT carry $a -- it enforces a different consensus payout"
        fi
    done

    # Carrying the right chain is not the same as running at all. v0.1.2
    # carried every correct constant and died with SIGILL on the first CPU
    # without AVX-512, because the node links a RandomX that had been built
    # with ARCH=native on the machine that produced the release. The archive
    # is already unpacked here, so the question costs nothing to ask.
    bash "$HERE/scripts/check_isa_baseline.sh" "$(dirname "$bin")"/* >"$d/isa.log" 2>&1
    isa_rc=$?
    # check_isa_baseline.sh prints one `reason:` line whenever it could not
    # run, and that line is the only thing worth quoting. This used to be
    # `head -1 isa.log`, which quoted the box-drawing banner instead --
    # "the CPU baseline was NOT checked: ====================".
    isa_reason="$(sed -n 's/^reason: //p' "$d/isa.log" | head -1)"

    if [ "$isa_rc" -eq 0 ]; then
        ok "no instruction above the x86-64 baseline"
    elif [ "$isa_rc" -eq 1 ]; then
        sed -n '/^  [a-z]/p' "$d/isa.log" | sed 's/^/         /'
        bad "these binaries carry instructions many CPUs do not have"
    elif [ "$isa_reason" != "${isa_reason#*is not installed}" ] \
         && [ "${WAM_ALREADY_REMOTE:-0}" != "1" ] \
         && [ -f "$HERE/scripts/lib/elsewhere.sh" ]; then
        # The tool is not here. This check reads FILES, so it cannot be
        # shipped the way check_dns_seeds.sh is -- but the question can be
        # asked again where the tool lives, by fetching the same published
        # URL there and running that host's own checker against it. Same
        # artifact, same question.
        # shellcheck source=lib/elsewhere.sh
        . "$HERE/scripts/lib/elsewhere.sh"
        isa_remote=""
        for h in $WAM_TOOL_HOSTS; do
            isa_remote="$(ssh -o BatchMode=yes -o ConnectTimeout=20 "root@$h" "
                set -u
                command -v objdump >/dev/null 2>&1 || exit 3
                command -v file    >/dev/null 2>&1 || exit 3
                [ -f $WAM_REMOTE_REPO/scripts/check_isa_baseline.sh ] || exit 3
                D=\$(mktemp -d); trap 'rm -rf \"\$D\"' EXIT; cd \"\$D\"
                curl -sSL --max-time 180 -O '$url' || exit 3
                case '$name' in
                    *.tar.gz) tar -xzf *.tar.gz || exit 3 ;;
                    *.zip)    command -v unzip >/dev/null 2>&1 || exit 3
                              unzip -qo *.zip   || exit 3 ;;
                esac
                bash $WAM_REMOTE_REPO/scripts/check_isa_baseline.sh \
                    \$(find \"\$D\" -type f -name 'wam*' ! -name '*.tar.gz' \
                       ! -name '*.zip' ! -name '*.md' ! -name '*.txt') >\"\$D/isa.log\" 2>&1
                rc=\$?
                sed -n 's/^reason: //p' \"\$D/isa.log\" | head -1
                exit \$rc
            " 2>/dev/null; echo "rc=$?")"
            # The remote's own reason comes back with it. Without this, a host
            # that answered "arm64, so the x86-64 baseline does not apply" was
            # indistinguishable from a host that could not be reached, and
            # both were reported as "no host could answer it either".
            case "${isa_remote##*rc=}" in
                0) ok "no instruction above the x86-64 baseline (checked on $h)"
                   break ;;
                1) bad "these binaries carry instructions many CPUs do not have
           (measured on $h)"
                   break ;;
                2) warn "the CPU baseline was NOT checked: $(printf '%s\n' "$isa_remote" \
                        | sed '$d' | head -1) (asked on $h)"
                   COULD_NOT_CHECK=1
                   isa_remote="answered"
                   break ;;
                *) isa_remote="" ;;        # this host has no tool: try the next
            esac
        done
        if [ -z "$isa_remote" ]; then
            warn "the CPU baseline was NOT checked: $isa_reason, and no host
           could answer it either"
            COULD_NOT_CHECK=1
        fi
    else
        # Anything that is not 0 and not 1 is the check saying it could not
        # run, and its own reason says why -- most often an arm64 build, for
        # which the x86-64 baseline is not a question at all.
        warn "the CPU baseline was NOT checked: ${isa_reason:-check_isa_baseline.sh exited $isa_rc}"
        COULD_NOT_CHECK=1
    fi
}

printf '\n%sdoes each published archive carry this network?%s\n' "$BLD" "$OFF"
for _row in "${ASSETS[@]}"; do
    check_artifact "$(printf '%s' "$_row" | cut -d' ' -f2)" \
                   "$(printf '%s' "$_row" | cut -d' ' -f3)"
done

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

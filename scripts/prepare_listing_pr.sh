#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  prepare_listing_pr.sh -- stage a venue's submission on a branch
# ===========================================================================
#
#      bash scripts/prepare_listing_pr.sh bisq
#      bash scripts/prepare_listing_pr.sh --list
#
#  Clones our fork of the venue's repository, copies this repository's files
#  into the paths that venue actually reads, commits with integration/<venue>/
#  PR.md as the message, and pushes a branch. It prints the URL that opens the
#  pull request and stops there: opening it is a decision, and it is the
#  founder's.
#
#  WHY THIS IS A SCRIPT
#
#  The Bisq submission was done by hand first -- clone, copy three files,
#  insert one line in alphabetical order, commit, push. It worked, and it left
#  nothing behind that anyone could check or repeat. Where each file goes in
#  each venue's tree is a fact about that venue, discovered by reading their
#  repository, and facts like that belong in a file rather than in whoever
#  did it last.
#
#  It also means a corrected file here reaches the venue by running one
#  command again, instead of by remembering which three paths it went to.
#
#  WHAT IT WILL NOT DO
#
#  Fork a repository or open a pull request. Both need a GitHub API token, and
#  a token pasted into a chat is a token that has to be revoked. Fork by hand,
#  once, and open the pull request from the link this prints.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

OWNER="wam-coin-official"
BRANCH="add-wam-coin"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
ok()   { printf '  %sok%s     %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '  %swarn%s   %s\n' "$YLW" "$OFF" "$*"; }
die()  { printf '  %sfail%s   %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
step() { printf '\n%s%s%s\n' "$BLD" "$*" "$OFF"; }

# venue | upstream repo | fork name
venues() {
    cat <<'V'
slips      satoshilabs/slips                          slips
bisq       bisq-network/bisq                          bisq
haveno     haveno-dex/haveno                          haveno
blockdx    blocknetdx/blockchain-configuration-files  blockchain-configuration-files
basicswap  tecnovert/basicswap                        basicswap
komodo     KomodoPlatform/coins                       coins
V
}

# Where each file goes in that venue's tree. "SRC -> DEST", one per line.
# Read out of each repository rather than guessed; see integration/<venue>/NOTES.md.
layout() {
    case "$1" in
    bisq) cat <<'L'
WAMCoin.java      assets/src/main/java/bisq/asset/coins/WAMCoin.java
WAMCoinTest.java  assets/src/test/java/bisq/asset/coins/WAMCoinTest.java
L
        ;;
    haveno) cat <<'L'
WAMCoin.java      assets/src/main/java/haveno/asset/coins/WAMCoin.java
WAMCoinTest.java  assets/src/test/java/haveno/asset/coins/WAMCoinTest.java
L
        ;;
    blockdx) cat <<'L'
xbridge-confs/wamcoin--v0.1.3.conf  xbridge-confs/wamcoin--v0.1.3.conf
wallet-confs/wamcoin--v0.1.3.conf   wallet-confs/wamcoin--v0.1.3.conf
L
        ;;
    basicswap) cat <<'L'
chainparams.py  basicswap/interface/wam/chainparams.py
wam.py          basicswap/interface/wam/wam.py
L
        ;;
    komodo) cat <<'L'
electrums-WAM.json  electrums/WAM
L
        ;;
    slips) : ;;   # both are edits to existing tables, handled below
    esac
}

if [ "${1:-}" = "--list" ] || [ $# -eq 0 ]; then
    printf 'venues:\n'
    venues | awk '{printf "  %-11s %s\n", $1, $2}'
    printf '\nusage: %s VENUE\n' "${0##*/}"
    exit 0
fi

VENUE="$1"
LINE="$(venues | awk -v v="$VENUE" '$1==v')"
[ -n "$LINE" ] || die "unknown venue '$VENUE' -- try --list"
UPSTREAM="$(printf '%s' "$LINE" | awk '{print $2}')"
FORK="$(printf '%s' "$LINE" | awk '{print $3}')"
SRCDIR="$HERE/integration/$VENUE"

[ -d "$SRCDIR" ] || die "no integration/$VENUE"
[ -f "$SRCDIR/PR.md" ] || die "no integration/$VENUE/PR.md -- the message is not optional"

echo "=================================================================="
echo " $VENUE  ->  $UPSTREAM"
echo "=================================================================="

# ---------------------------------------------------------------------------
step "1. our fork"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
if ! git clone --quiet --depth 30 "git@github.com:$OWNER/$FORK.git" "$W/repo" 2>/dev/null; then
    die "cannot clone git@github.com:$OWNER/$FORK.git

           Fork it once, by hand, at:
               https://github.com/$UPSTREAM/fork"
fi
cd "$W/repo"
ok "$(git log --oneline -1)"

DEFAULT="$(git symbolic-ref --short HEAD)"

# A branch already there is the normal case on a second run, and pushing over
# it silently would discard whatever is on it -- possibly a submission already
# under review. Start from it instead, so a re-run updates rather than
# replaces, and say which is happening.
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    # An explicit refspec, because a shallow clone fetches only the default
    # branch and `git fetch origin BRANCH` then lands in FETCH_HEAD without
    # creating origin/BRANCH. Written the short way once, the checkout below
    # failed, the script carried on regardless, and it committed onto the
    # default branch and tried to push a branch that did not exist. The fetch
    # being wrong was the small half; continuing after it failed was the rest.
    git fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" \
        || die "cannot fetch $BRANCH from the fork"
    git checkout -q -b "$BRANCH" "origin/$BRANCH" \
        || die "cannot start from origin/$BRANCH"
    warn "$BRANCH already exists on the fork -- updating it, not replacing it"
    EXISTING=1
else
    git checkout -q -b "$BRANCH" || die "cannot create branch $BRANCH"
    EXISTING=0
fi

# ---------------------------------------------------------------------------
step "2. files"

COPIED=0
while read -r src dest; do
    [ -n "${src:-}" ] || continue
    [ -f "$SRCDIR/$src" ] || die "integration/$VENUE/$src is missing"
    # A destination directory that does not exist means their layout moved and
    # this script's idea of it is stale. Say so rather than inventing a tree.
    parent="$(dirname "$dest")"
    [ "$parent" = "." ] || [ -d "$parent" ] \
        || die "$UPSTREAM has no $parent/ -- their layout changed; re-read it before guessing"
    cp "$SRCDIR/$src" "$dest"
    ok "$src -> $dest"
    COPIED=$((COPIED + 1))
done < <(layout "$VENUE")

# ---- the per-venue edits that are not file copies --------------------------
case "$VENUE" in
bisq|haveno)
    NS="$VENUE"; [ "$VENUE" = "bisq" ] && NS="bisq" || NS="haveno"
    SVC="assets/src/main/resources/META-INF/services/$NS.asset.Asset"
    [ -f "$SVC" ] || die "no $SVC"
    python3 - "$SVC" "$NS.asset.coins.WAMCoin" <<'PY'
import sys, pathlib
p, entry = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = p.read_text(encoding="utf-8").splitlines()
if entry in lines:
    print("  ok     already registered"); raise SystemExit
prefix = entry.rsplit(".", 1)[0] + "."
idx = next((i for i, l in enumerate(lines)
            if l.startswith(prefix) and l.lower() > entry.lower()), None)
if idx is None:
    idx = max(i for i, l in enumerate(lines) if l.startswith(prefix)) + 1
lines.insert(idx, entry)
p.write_text("\n".join(lines) + "\n", encoding="utf-8")
print("  ok     %s, between %s and %s"
      % (entry.rsplit('.', 1)[1], lines[idx-1].rsplit('.', 1)[1],
         lines[idx+1].rsplit('.', 1)[1] if idx+1 < len(lines) else "the end"))
PY
    COPIED=$((COPIED + 1))
    ;;
basicswap)
    mkdir -p basicswap/interface/wam
    : > basicswap/interface/wam/__init__.py
    ok "basicswap/interface/wam/__init__.py"
    warn "Coins enum member and the import in basicswap/chainparams.py are not"
    warn "automated -- their file's shape is Python, not a list, and a script"
    warn "that edits it blind is how a bad patch reaches a reviewer."
    ;;
slips)
    # Two rows in two existing tables. Not files to add -- the repository's
    # "upload files" page is the wrong door, and a new file there would be
    # closed without comment.
    #
    # Column widths are measured from a neighbouring row rather than written
    # here, so the diff a reviewer sees is one line and not a reformatting.
    COIN_TYPE="$(grep -oE 'WAM_BIP44_COIN_TYPE[[:space:]]*=[[:space:]]*(0x[0-9A-Fa-f]+|[0-9]+)' \
        "$HERE/src/wam/wam-params.h" | grep -oE '(0x[0-9A-Fa-f]+|[0-9]+)$' | tail -1)"
    [ -n "$COIN_TYPE" ] || die "cannot read WAM_BIP44_COIN_TYPE from the source"
    python3 - "$COIN_TYPE" <<'PY'
import pathlib, re, sys

coin = int(sys.argv[1], 0)


def widths(line):
    # "| a | b | c |" -> the width of each cell as written
    return [len(c) for c in line.split("|")[1:-1]]


# ---- slip-0044.md : numeric order -----------------------------------------
p = pathlib.Path("slip-0044.md")
lines = p.read_text(encoding="utf-8").splitlines()
rows = [(i, int(m.group(1))) for i, l in enumerate(lines)
        for m in [re.match(r"^\|\s*(\d+)\s*\|", l)] if m]
if any(n == coin for _, n in rows):
    print("  ok     slip-0044.md already has %d" % coin)
else:
    nxt = min((r for r in rows if r[1] > coin), key=lambda r: r[1])
    w = widths(lines[nxt[0]])
    row = "|" + str(coin).ljust(w[0] - 1).rjust(w[0]) \
        + "|" + " WAM".ljust(w[1]) \
        + "|" + " WAM Coin".ljust(w[2]) + "|"
    # rebuild with a leading space in each cell, matching the file
    row = "| %s| %s| %s|" % (str(coin).ljust(w[0] - 1),
                             "WAM".ljust(w[1] - 1),
                             "WAM Coin".ljust(w[2] - 1))
    lines.insert(nxt[0], row)
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("  ok     slip-0044.md: %d, above %s" % (coin, lines[nxt[0] + 1].strip()[:40]))

# ---- slip-0173.md : alphabetical by coin name ------------------------------
p = pathlib.Path("slip-0173.md")
lines = p.read_text(encoding="utf-8").splitlines()
if any("WAM Coin" in l for l in lines):
    print("  ok     slip-0173.md already has WAM Coin")
else:
    # Only the table under "Registered human-readable parts". The file holds
    # several -- "Non-Segwit-compatible uses of Bech32 / Bech32m" and "Uses of
    # codex32" follow it -- and an unbounded scan put WAM between Mnemonic Key
    # and Zcash's viewing keys, which is a different table about a different
    # thing entirely.
    start = next(i for i, l in enumerate(lines)
                 if l.startswith("## Registered human-readable parts"))
    end = next((i for i, l in enumerate(lines[start + 1:], start + 1)
                if l.startswith("## ")), len(lines))
    names = [(i, re.match(r"^\|\s*([^|]+?)\s*\|", l).group(1))
             for i, l in enumerate(lines)
             if start < i < end and re.match(r"^\|\s*[^|\s-]", l) and "`" in l]
    # The first name greater than ours is not good enough: their table has
    # stragglers -- "Wormhole Gateway" sits between Galaxy and GenesisL1 --
    # and landing beside one produces a diff that looks careless even though
    # it is one line. Insert where the neighbours are ordered with respect to
    # each other, which is the run a reader would call alphabetical.
    # The LAST position that fits, not the first. Their table has stragglers --
    # "Wormhole Gateway" sits between Galaxy and GenesisL1 -- and every one of
    # them offers a gap that satisfies prev < ours < next while sitting
    # nowhere near the alphabet. The strays are near the top and the long
    # sorted run is below them, so the last candidate is the one inside it: for
    # us that is between VIPSTARCOIN and Wpc rather than above Wormhole.
    key = "wam coin"
    idx = None
    for a, b in zip(names, names[1:]):
        if a[1].lower() < key < b[1].lower():
            idx = b[0]
    if idx is None:
        after = [x for x in names if x[1].lower() > key]
        idx = after[0][0] if after else names[-1][0] + 1
    w = widths(lines[idx])
    row = "| %s| %s| %s| %s|" % ("WAM Coin".ljust(w[0] - 1),
                                 "`wam`".ljust(w[1] - 1),
                                 "`twam`".ljust(w[2] - 1),
                                 "`wamrt`".ljust(w[3] - 1))
    lines.insert(idx, row)
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("  ok     slip-0173.md: wam/twam/wamrt, above %s" % lines[idx + 1].strip()[:40])
PY
    COPIED=$((COPIED + 1))
    ;;
esac

[ "$COPIED" -gt 0 ] || die "nothing was staged"

# ---------------------------------------------------------------------------
step "3. commit"

git add -A
if git diff --cached --quiet; then
    if [ "$EXISTING" = 1 ]; then
        ok "the branch already carries exactly these files; nothing to do"
        echo
        echo " Open the pull request here:"
        echo "   https://github.com/$UPSTREAM/compare/$DEFAULT...$OWNER:$FORK:$BRANCH?expand=1"
        exit 0
    fi
    die "nothing changed -- the files may already be in their tree"
fi
git -c user.name="Waleed Ahmed Mare Alshaybani" \
    -c user.email="waleedahmedmarealshaybani@gmail.com" \
    commit -q -F "$SRCDIR/PR.md"
git show --stat --oneline HEAD | tail -n +2 | sed 's/^/  /'

# ---------------------------------------------------------------------------
step "4. push"

# Status read from git, not from the end of a pipe. Written as a pipeline
# once, this printed "ok pushed" over "failed to push some refs" -- the exit
# code belonged to sed. That is the same fault this repository has spent a day
# removing from other checks, introduced fresh in the script that stages the
# submissions.
PUSHLOG="$W/push.log"
if git push --set-upstream origin "$BRANCH" >"$PUSHLOG" 2>&1; then
    grep -v '^remote:' "$PUSHLOG" | sed 's/^/  /'
    ok "pushed $OWNER/$FORK:$BRANCH"
else
    sed 's/^/  /' "$PUSHLOG"
    die "the push failed -- nothing is staged on the fork"
fi

echo
echo "=================================================================="
echo " Open the pull request here:"
echo
echo "   https://github.com/$UPSTREAM/compare/$DEFAULT...$OWNER:$FORK:$BRANCH?expand=1"
echo
echo " The title and body are already filled from integration/$VENUE/PR.md."
echo "=================================================================="

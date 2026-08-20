#!/bin/bash
# ===========================================================================
#  audit_repo.sh -- does the repository still say what is true?
# ===========================================================================
#
#      bash scripts/audit_repo.sh
#
#  A project's documentation rots silently. A consensus rule changes and eleven
#  files still describe the old one; an asset is renamed and a page links to
#  nothing; a chain is re-launched and a listing page names a genesis block that
#  no longer exists. None of it breaks a build. All of it is read by exactly the
#  people whose opinion matters most -- reviewers, integrators, exchanges -- and
#  to them a stale number is indistinguishable from a lie.
#
#  This script is the check that a person cannot be relied on to repeat. It
#  fails loudly and it is cheap enough to run before every push.
#
#  What it refuses to let pass:
#
#    1. A file path referenced anywhere that does not exist
#    2. Any superseded genesis hash, anywhere
#    3. Any claim that part of the founder reserve is liquid at launch
#    4. The three copies of the vesting schedule disagreeing
#    5. References to directories that were retired
#    6. Placeholder values that were meant to be replaced before launch
# ===========================================================================

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; OFF=$'\033[0m'
FAILURES=0
fail() { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$*"; FAILURES=$((FAILURES + 1)); }
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; }
step() { printf '\n%s%s%s\n' "$CYN" "$*" "$OFF"; }

# Everything below skips build output, dependencies and untracked scratch.
SEARCH=(--include=*.md --include=*.html --include=*.js --include=*.py
        --include=*.sh --include=*.cpp --include=*.h --include=*.json
        --include=*.service --include=*.yml)
EXCLUDE='node_modules|^\./build/|^\./out/|^\./brand/legacy/|^\./PROGRESS\.md|^\./review/'

# ---------------------------------------------------------------------------
step "1. every referenced file exists"

# Files that are referenced on purpose without existing in the repository:
# configs a user creates from an example, and anything .gitignore keeps out.
EXPECTED_ABSENT='pool/config\.json|bots/config\.json|.*/config\.json$'

# -o without -h prints "path:match", so the exclusion can filter on the file
# the reference lives in. With -h the filenames are gone and $EXCLUDE matches
# nothing -- which is why this first reported every path inside legacy/, a
# directory it is explicitly told to skip.
MISSING=0
for ref in $(grep -roE '(brand|docs|scripts|genesis|deploy|site|pool|explorer|bots|miner)/[A-Za-z0-9/_.-]+\.(svg|png|jpg|md|sh|py|js|json|service|yml)' \
             "${SEARCH[@]}" . 2>/dev/null | grep -vE "$EXCLUDE" | cut -d: -f2- | sort -u); do
    printf '%s' "$ref" | grep -qE "$EXPECTED_ABSENT" && continue
    [ -e "$ref" ] || { fail "referenced but missing: $ref"; MISSING=$((MISSING + 1)); }
done
[ "$MISSING" = 0 ] && ok "no broken file references"

# ---------------------------------------------------------------------------
step "2. no superseded genesis hash survives"

# Every hash this project has ever asserted and then replaced.
DEAD_HASHES=(
    b66685143044db0a   # testnet, before the reserve was locked
    2b1469b34052506a   # its merkle root
    1fa171c2abc3cd0b   # regtest, same
    bbbd737e2aa2fd83   # mainnet, burn-address placeholder
    51e7dd7b7b6e4684   # its merkle root
    52a818ac926d30d8   # mainnet merkle, first tranche unlocked
)
DEAD=0
for h in "${DEAD_HASHES[@]}"; do
    HITS=$(grep -rl "$h" "${SEARCH[@]}" . 2>/dev/null | grep -vE "$EXCLUDE|audit_repo" || true)
    [ -n "$HITS" ] && { fail "superseded hash $h still in: $(echo $HITS | tr '\n' ' ')"; DEAD=$((DEAD + 1)); }
done
[ "$DEAD" = 0 ] && ok "no superseded genesis hash anywhere"

# ---------------------------------------------------------------------------
step "3. nothing claims the reserve is liquid at launch"

# Phrases that were true before 2026-08-18 and are now false. The negative
# lookahead skips the sentences that exist precisely to deny them.
# The negations are as important as the pattern. Half the places that mention
# "liquid at launch" now exist specifically to deny it, and a check that cannot
# tell a claim from its denial gets switched off within a week.
NEGATED='none.{0,4} is liquid|nothing liquid|NONE liquid|none of it|no tranche|not liquid'
NEGATED="$NEGATED|used to|did not survive|does not need|may be liquid|is 0%|means a tranche is"
NEGATED="$NEGATED|must not|that justification|nothing in the reserve|لا شيء"

STALE=$(grep -rniE '(1\.82%|20% liquid|liquid at launch|liquid on launch day|unlocked at genesis|tranche 1 is spendable|launch working capital|vested to 2030)' \
        "${SEARCH[@]}" . 2>/dev/null \
        | grep -vE "$EXCLUDE|audit_repo" \
        | grep -viE "$NEGATED" || true)
if [ -n "$STALE" ]; then
    fail "text still describes the old vesting schedule:"
    printf '%s\n' "$STALE" | head -8 | sed 's/^/          /'
else
    ok "no claim that any tranche is liquid at launch"
fi

# ---------------------------------------------------------------------------
step "4. the three vesting tables agree"

if python3 scripts/check_vesting_sync.py >/dev/null 2>&1; then
    ok "wam-params.h, the generator and the explorer carry the same schedule"
else
    fail "vesting schedules disagree -- run scripts/check_vesting_sync.py"
fi

# ---------------------------------------------------------------------------
step "5. retired components are not referenced"

RETIRED=0
for dir in telegram; do
    HITS=$(grep -rl "$dir/" "${SEARCH[@]}" . 2>/dev/null | grep -vE "$EXCLUDE|audit_repo" || true)
    [ -n "$HITS" ] && { fail "retired '$dir/' referenced in: $(echo $HITS | tr '\n' ' ')"; RETIRED=$((RETIRED + 1)); }
done
[ "$RETIRED" = 0 ] && ok "no references to retired directories"

# ---------------------------------------------------------------------------
step "6. placeholders that must not reach launch"

PLACEHOLDER=0
BURN="WNg2svm2qApxheBKndKGQ9sRwporvRgRpT"

# The burn address, hash160 of twenty zero bytes. Anything paid to it is gone.
if grep -q "WAM_FOUNDER_ADDRESS_MAINNET = \"$BURN\"" src/wam/chainparams.cpp 2>/dev/null; then
    fail "the mainnet founder address is still the burn placeholder"
    PLACEHOLDER=$((PLACEHOLDER + 1))
fi
if grep -q "WAM_TREASURY_ADDRESS_MAINNET = \"$BURN\"" src/wam/chainparams.cpp 2>/dev/null; then
    printf '  %swarn%s  the mainnet treasury address is still the burn placeholder.\n' "$YLW" "$OFF"
    printf '        750,000 WAM of operating income would be destroyed. Generate a\n'
    printf '        second key offline -- not the founder key -- before launch.\n'
fi
if grep -rq "WCHANGEme" pool/config.json 2>/dev/null; then
    fail "pool/config.json still has a placeholder payout address"
    PLACEHOLDER=$((PLACEHOLDER + 1))
fi

# The whole point of two constants is that they hold two different values.
# Setting them back to one address would restore the arrangement that made
# treasury spending indistinguishable from founder selling, and it would do it
# silently -- nothing fails, the chain runs, and only an auditor notices.
for NET in MAINNET TESTNET; do
    F=$(grep -oP "WAM_FOUNDER_ADDRESS_$NET = \"\K[^\"]+" src/wam/chainparams.cpp 2>/dev/null)
    T=$(grep -oP "WAM_TREASURY_ADDRESS_$NET = \"\K[^\"]+" src/wam/chainparams.cpp 2>/dev/null)
    if [ -n "$F" ] && [ "$F" = "$T" ]; then
        fail "$NET founder and treasury are the same address; they must differ"
        PLACEHOLDER=$((PLACEHOLDER + 1))
    fi
done

[ "$PLACEHOLDER" = 0 ] && ok "no launch-blocking placeholders; founder and treasury differ"

# ---------------------------------------------------------------------------
step "7. claims about maturity and duration are current"

# The founder reserve was locked over five years, not four, on 2026-08-18. The
# whole documentation set said four, in seven places, and none of the earlier
# checks noticed -- they searched for "liquid at launch" and this is a duration.
# A reader comparing "vested over 4 years" against a schedule ending in 2031
# concludes the project cannot keep its own numbers straight.
DURATION=$(grep -rniE '(vested|locked|vesting).{0,24}(4 years|four years)|20% per year to 2030|to 2030-09-15' \
           "${SEARCH[@]}" . 2>/dev/null | grep -vE "$EXCLUDE|audit_repo" \
           | grep -viE 'zcash|dash|decred|monero|for comparison' || true)
if [ -n "$DURATION" ]; then
    fail "the reserve is described as four years somewhere; it is five:"
    printf '%s\n' "$DURATION" | head -6 | sed 's/^/          /'
else
    ok "the reserve is described as five years everywhere"
fi

# Claims that were true before the code was first compiled. They are the first
# thing a reviewer reads about maturity, and they age badly and silently.
MATURITY=$(grep -rniE 'nothing has been compiled|never been through a compiler|have never been applied|no chain exists yet' \
           "${SEARCH[@]}" . 2>/dev/null | grep -vE "$EXCLUDE|audit_repo" || true)
if [ -n "$MATURITY" ]; then
    fail "text still says the project has never been compiled:"
    printf '%s\n' "$MATURITY" | head -4 | sed 's/^/          /'
else
    ok "no stale claim that nothing has been built"
fi

# ---------------------------------------------------------------------------
step "8. the integration files still match the chain"

# integration/ duplicates chain parameters for venues that consume a config
# file rather than a form. They cannot share a definition -- one is JSON that
# Komodo reads, one is an ini that Block DX reads, and the source of truth is
# C++. So they are copies, and a copy that drifts is an integration that fails
# on the first connection, from a venue that does not come back to ask why.
INTEG=0
if [ -d integration ]; then
    GEN_MAIN=$(grep -oP 'hashGenesisBlock == uint256S\("0x\K[0-9a-f]{64}' src/wam/chainparams.cpp | head -1)
    GEN_TEST=$(grep -oP 'hashGenesisBlock == uint256S\("0x\K[0-9a-f]{64}' src/wam/chainparams.cpp | sed -n 2p)

    # Every 64-hex string in the files venues read must be a chain hash this
    # source declares -- or must say on the same line what else it is.
    #
    # This used to name integration/basicswap/wam.json and check two hashes in
    # it. When BasicSwap turned out to consume a Python package rather than
    # JSON and the file went away, the check reported "wrong mainnet genesis
    # hash" about a file that did not exist: a true failure with a false
    # reason, which sends the next reader looking in the wrong place.
    #
    # Asking the question of every file instead means no filename here can go
    # stale, and a genesis hash that survives a re-mine anywhere in the
    # published material is caught wherever it is hiding.
    GEN_ALL="$(grep -oP 'hashGenesisBlock == uint256S\("0x\K[0-9a-f]{64}' src/wam/chainparams.cpp)"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        f="${line%%:*}"; rest="${line#*:}"
        h="$(printf '%s' "$rest" | grep -oE '\b[0-9a-f]{64}\b' | head -1)"
        printf '%s\n' "$GEN_ALL" | grep -qx "$h" && continue
        # Not a genesis hash. It may still be legitimate -- the listing package
        # quotes the genesis merkle root -- but it has to say so where it sits,
        # so a stale hash can never pass as a labelled one.
        printf '%s' "$rest" | grep -qiE 'merkle' && continue
        fail "$f carries ${h:0:16}..., which is neither a genesis hash nor labelled"
        INTEG=$((INTEG+1))
    done <<< "$(grep -rEn '\b[0-9a-f]{64}\b' integration/ docs/ 2>/dev/null)"

    # Address prefixes, in every file that repeats them. A named file that has
    # gone missing is reported as missing rather than as wrong.
    for f in integration/komodo/coin-entry.json \
             integration/blockdx/xbridge-confs/wamcoin--v0.1.3.conf \
             integration/basicswap/chainparams.py; do
        if [ ! -f "$f" ]; then
            fail "$f is gone -- either it moved and this list is stale, or a venue's files were lost"
            INTEG=$((INTEG+1)); continue
        fi
        grep -q '\b73\b' "$f" && grep -q '\b135\b' "$f" \
            || { fail "$f is missing an address prefix (73 pubkey / 135 script)"; INTEG=$((INTEG+1)); }
    done

    # Nowhere may a SLIP-44 coin type be invented while none is registered.
    # A wrong one derives every user's keys onto a branch no other wallet
    # looks at, and it is the kind of number that gets copied once and lives
    # forever.
    if grep -rEn '^[^#]*"?(bip44|derivation_path|coin_type)"?[[:space:]]*[:=][[:space:]]*[0-9]' \
            integration/ 2>/dev/null | grep -v ': 1,' | head -3 | grep -q .; then
        grep -rEn '^[^#]*"?(bip44|derivation_path|coin_type)"?[[:space:]]*[:=][[:space:]]*[0-9]' \
            integration/ 2>/dev/null | grep -v ': 1,' | head -3 | sed 's/^/         /'
        fail "a SLIP-44 coin type is set somewhere in integration/, and none is registered"
        INTEG=$((INTEG+1))
    fi

    # The message prefix Komodo asks for by name, against the patch rule.
    if grep -q 'WAM Coin Signed Message' scripts/patch_upstream.py 2>/dev/null; then
        grep -q 'WAM Coin Signed Message' integration/komodo/coin-entry.json 2>/dev/null \
            || { fail "komodo/coin-entry.json does not carry the WAM message prefix"; INTEG=$((INTEG+1)); }
    fi

    # A derivation path without a registered SLIP-44 type would send funds to a
    # branch no other wallet looks at.
    if grep -q 'derivation_path' integration/komodo/coin-entry.json 2>/dev/null; then
        fail "komodo/coin-entry.json has a derivation_path but no SLIP-44 type is registered"
        INTEG=$((INTEG+1))
    fi

    [ "$INTEG" = 0 ] && ok "integration/ agrees with the consensus source"
else
    ok "no integration/ directory yet"
fi

# ---------------------------------------------------------------------------
printf '\n%s\n' "$(printf '=%.0s' {1..70})"
if [ "$FAILURES" = 0 ]; then
    printf ' %sthe repository agrees with itself%s\n' "$GRN" "$OFF"
else
    printf ' %s%d check(s) failed%s\n' "$RED" "$FAILURES" "$OFF"
fi
printf '%s\n' "$(printf '=%.0s' {1..70})"
exit $((FAILURES > 0))

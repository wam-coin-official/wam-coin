#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_dns_seeds.sh -- can a stranger actually find this network?
# ===========================================================================
#
#      bash scripts/check_dns_seeds.sh [mainnet|testnet|all]
#
#  Bitcoin Core never asks DNS for the seed name written in chainparams. It
#  asks for a *prefixed* name (net.cpp):
#
#      std::string host = strprintf("x%x.%s", requiredServiceBits, seed);
#
#  where the prefix encodes the service flags a usable peer must advertise --
#  in practice `x9.` for NODE_NETWORK|NODE_WITNESS. So an A record at the bare
#  name is never queried. The node logs
#
#      Loading addresses from DNS seed testnet-seed.wamcoin.org.
#      0 addresses found from DNS seeds
#
#  and carries on as though seeding simply had nothing to offer. `dig` on the
#  bare name answers perfectly, which is what makes this so easy to declare
#  finished.
#
#  A real DNS seeder runs a custom nameserver that parses the prefix. For a
#  small static seed a wildcard is enough and correct:
#
#      A   *.testnet-seed   ->  <node ip>
#      A   *.seed1          ->  <node ip>
#
#  The consequence of getting it wrong is not subtle: nobody who installs the
#  software can join the network, on launch day, with no error message. This
#  script is the check that must pass before a launch is announced.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAINPARAMS="$HERE/src/wam/chainparams.cpp"
TARGET="${1:-all}"

GREEN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; OFF=$'\033[0m'
FAIL=0

command -v dig >/dev/null 2>&1 || {
    printf 'dig is not installed:  sudo apt-get install -y dnsutils\n' >&2
    exit 1
}

# x9 = NODE_NETWORK (1) | NODE_WITNESS (8). This is what Core asks for; if
# upstream ever changes SeedsServiceFlags() this constant must follow it.
PREFIX="x9"

check_seed() {
    local seed="$1" net="$2" bare prefixed
    seed="${seed%.}"                       # chainparams writes a trailing dot

    bare="$(dig +short +time=3 +tries=2 "$seed" A 2>/dev/null | head -3 | tr '\n' ' ')"
    prefixed="$(dig +short +time=3 +tries=2 "${PREFIX}.${seed}" A 2>/dev/null | head -3 | tr '\n' ' ')"

    printf '  %-34s [%s]\n' "$seed" "$net"
    printf '      bare              %s\n' "${bare:-—}"
    printf '      %-17s %s\n' "${PREFIX}. (what Core asks)" "${prefixed:-—}"

    if [ -n "$prefixed" ]; then
        printf '      %sok%s    seeding works\n\n' "$GREEN" "$OFF"
        return 0
    fi

    if [ -n "$bare" ]; then
        printf '      %sFAIL%s  the bare name resolves but %s.%s does not.\n' \
            "$RED" "$OFF" "$PREFIX" "$seed"
        printf '            Core will find 0 addresses here. Add a wildcard:\n'
        printf '                A   *.%s   ->   %s\n\n' \
            "${seed%%.*}" "$(printf '%s' "$bare" | awk '{print $1}')"
    else
        printf '      %sFAIL%s  does not resolve at all -- no record, or not propagated.\n\n' \
            "$RED" "$OFF"
    fi
    FAIL=$((FAIL + 1))
    return 1
}

echo "=================================================================="
echo " DNS seeds -- as Bitcoin Core actually queries them"
echo "=================================================================="
echo

# Read the seed names out of chainparams rather than repeating them here, so a
# seed added to the code without a matching DNS record fails this check.
mapfile -t MAIN_SEEDS < <(
    awk '/CreateChainParams|class CMainParams|SigNetParams|CRegTestParams/{blk=$0}
         /vSeeds\.emplace_back\("seed[0-9]/ {
            if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2)
         }' "$CHAINPARAMS" 2>/dev/null
)
mapfile -t TEST_SEEDS < <(
    awk '/vSeeds\.emplace_back\("testnet-seed/ {
            if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2)
         }' "$CHAINPARAMS" 2>/dev/null
)

[ "${#MAIN_SEEDS[@]}" -gt 0 ] || printf '  %swarn%s  no mainnet seeds found in chainparams\n' "$YLW" "$OFF"
[ "${#TEST_SEEDS[@]}" -gt 0 ] || printf '  %swarn%s  no testnet seeds found in chainparams\n' "$YLW" "$OFF"

if [ "$TARGET" = "testnet" ] || [ "$TARGET" = "all" ]; then
    for s in "${TEST_SEEDS[@]:-}"; do [ -n "$s" ] && check_seed "$s" testnet; done
fi

if [ "$TARGET" = "mainnet" ] || [ "$TARGET" = "all" ]; then
    for s in "${MAIN_SEEDS[@]:-}"; do [ -n "$s" ] && check_seed "$s" mainnet; done
fi

echo "=================================================================="
if [ "$FAIL" -eq 0 ]; then
    printf ' %sall seeds answer the prefixed query%s\n' "$GREEN" "$OFF"
else
    printf ' %s%d seed(s) unusable -- a new node would find nobody%s\n' "$RED" "$FAIL" "$OFF"
    echo
    echo ' Mainnet seeds are expected to fail until the launch DNS is in place.'
    echo ' A testnet failure means the running testnet cannot be joined today.'
fi
echo "=================================================================="
[ "$FAIL" -eq 0 ]

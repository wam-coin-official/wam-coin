#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_dnssec.py -- is the zone signed, and does anyone actually validate it?
# ===========================================================================
#
#      python3 scripts/check_dnssec.py
#
#  WHY THIS EXISTS
#
#  Not because signing the zone was hard. Because nothing here measured it.
#
#  DNSSEC was enabled and the DS record took time to appear at .org. It was
#  measured once, while it was still absent, and that measurement became a
#  line in a list of outstanding work -- repeated for days, in every summary,
#  long after the record was live and validating. A fact measured once had
#  become a belief.
#
#  The contrast is the whole argument. check_dns_seeds.sh exists, so when a
#  bare A query for seed1.wamcoin.org came back empty on 6 September and was
#  announced as a serious fault, the check corrected it in minutes: Bitcoin
#  Core asks `x9.seed1...`, not the bare name, and the seeds were healthy.
#  DNSSEC had no check, so the wrong claim about it survived for days. The
#  difference between the two was one script.
#
#  WHAT IT ASKS, AND OF WHOM
#
#  Two independent public resolvers, over HTTPS, because dig is not installed
#  on the machine this project is developed on and a check that only runs
#  where a tool happens to exist is a check that reports nothing on the day
#  it matters.
#
#  Asking two also answers a question one cannot: a single resolver's cache
#  can be stale in either direction. Agreement between Google and Cloudflare
#  is not proof, but disagreement is worth knowing about.
#
#  AD -- "authenticated data" -- is the resolver saying it followed the chain
#  of trust from the root and the signatures held. It is the only field here
#  that means anything about security; a DS record that exists but does not
#  validate is decoration.
# ===========================================================================

import json
import re
import subprocess
import sys
import urllib.parse

DOMAIN = "wamcoin.org"
if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
    DOMAIN = sys.argv[1]      # so the failure path can be proved

# The seeds are asked the way Bitcoin Core asks them -- prefixed with the
# service-bit filter. The bare name is not expected to answer and its silence
# is not a fault, which is exactly the mistake this file was written after.
SEED_PREFIX = "x9."

RESOLVERS = [
    ("Google", "https://dns.google/resolve?"),
    ("Cloudflare", "https://cloudflare-dns.com/dns-query?"),
]

GRN, RED, YLW, BLD, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[0m"

_fails, _warns = [], []


def ok(m):   print(f"  {GRN}ok{OFF}    {m}")
def bad(m):  print(f"  {RED}FAIL{OFF}  {m}"); _fails.append(m)
def warn(m): print(f"  {YLW}!!{OFF}    {m}"); _warns.append(m)


def query(base, name, rrtype):
    """One DoH question. Returns the parsed answer, or None if unreachable."""
    url = base + urllib.parse.urlencode({"name": name, "type": rrtype, "do": "1"})
    try:
        r = subprocess.run(
            ["curl", "-s", "--max-time", "20",
             "-H", "accept: application/dns-json", url],
            capture_output=True, text=True, timeout=40)
        return json.loads(r.stdout)
    except Exception:
        return None


def seeds_from_chainparams():
    """The seed names the software will actually ask for."""
    import pathlib
    p = pathlib.Path(__file__).resolve().parent.parent / "src" / "wam" / "chainparams.cpp"
    try:
        text = p.read_text(encoding="utf-8")
    except OSError:
        return []
    return [n.rstrip(".") for n in
            re.findall(r'vSeeds\.emplace_back\("([^"]+)"\)', text)]


def main():
    print(f"\n{BLD}the zone is signed, and resolvers validate it{OFF}")

    reachable = 0

    # ---- 1. is there a DS record at the parent, and does the chain hold? ----
    for who, base in RESOLVERS:
        d = query(base, DOMAIN, "DS")
        if d is None:
            warn(f"{who} did not answer")
            continue
        reachable += 1
        ds = [a for a in (d.get("Answer") or []) if a.get("type") == 43]
        if not ds:
            bad(f"{who}: no DS record for {DOMAIN} at its parent")
            print("        Without it the signatures are decoration: a resolver")
            print("        has no way to know the zone is supposed to be signed.")
            continue
        if not d.get("AD"):
            bad(f"{who}: a DS record exists but the answer is not authenticated")
            print("        The chain of trust does not hold. A signed zone that")
            print("        does not validate protects nobody.")
            continue
        ok(f"{who}: DS present and the answer is authenticated (AD)")

    if reachable == 0:
        # Exit 2 is this project's convention for "the check could not run".
        # A network this machine cannot reach is not a finding about the zone.
        warn("no resolver could be reached, so nothing was measured")
        print()
        return 2

    # ---- 2. is the zone's own key published and signed? --------------------
    d = query(RESOLVERS[0][1], DOMAIN, "DNSKEY")
    if d is not None:
        keys = [a for a in (d.get("Answer") or []) if a.get("type") == 48]
        sigs = [a for a in (d.get("Answer") or []) if a.get("type") == 46]
        if keys and sigs:
            ok(f"the zone publishes {len(keys)} key(s) and they are signed")
        elif keys:
            bad("DNSKEY records exist but carry no RRSIG -- unsigned keys")
        else:
            bad("the zone publishes no DNSKEY")

    # ---- 3. the names the software will ask for ----------------------------
    #
    # Not the bare seed name. Core prefixes the query, and a bare seed
    # answering nothing is correct behaviour that was once reported here as a
    # serious fault.
    seeds = seeds_from_chainparams()
    if not seeds:
        warn("no seed names could be read from chainparams.cpp")
    else:
        answered = 0
        for name in seeds:
            d = query(RESOLVERS[0][1], SEED_PREFIX + name, "A")
            if d is None:
                warn(f"{SEED_PREFIX}{name}: resolver did not answer")
                continue
            addrs = [a["data"] for a in (d.get("Answer") or []) if a.get("type") == 1]
            if not addrs:
                bad(f"{SEED_PREFIX}{name} returns no address -- a new node "
                    f"cannot find the network through it")
                continue
            if not d.get("AD"):
                warn(f"{SEED_PREFIX}{name} answers but the answer is not "
                     f"authenticated")
            answered += 1
        if answered:
            ok(f"{answered} of {len(seeds)} seed(s) answer the query Core makes "
               f"({SEED_PREFIX})")

    print()
    if _fails:
        print(f"  {RED}{len(_fails)} finding(s){OFF}\n")
        return 1
    if _warns:
        print(f"  {GRN}the chain of trust holds{OFF}, with "
              f"{len(_warns)} thing(s) worth reading above\n")
        return 0
    print(f"  {GRN}{BLD}the chain of trust holds from the root{OFF}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

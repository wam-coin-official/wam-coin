#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""
===============================================================================
 check_published_claims.py -- does what we TELL people match what the chain does
===============================================================================

     python3 scripts/check_published_claims.py

 WHY THIS EXISTS

 On 1 September 2026 the founder read the whitepaper on his telephone and
 found a table saying the first founder tranche unlocks on launch day. It
 does not. Every tranche has been locked since the decision to remove the
 liquid one, and consensus enforces it. The same file said the right thing in
 its prose on line 132 and the wrong thing in its table on line 268.

 The sweep had just reported 28 checks passed, including one called "vesting
 tables agree". That check compares three MACHINE-READABLE copies -- the C++
 header, the Python genesis miner, the explorer's JS constants -- and they did
 agree. It reads no document a human reads. Neither did anything else here.

 So every check in this project compared code to code, and nothing compared
 the published claim to the enforced rule. That is not one stale table. It is
 a whole class of error with no detector, and the founder was right to say so
 before being shown a second example.

 WHAT THIS DOES

 wam-params.h is the authority -- it is what the network enforces. For each
 constant below, this finds every place a published document states a value
 for it, and fails on any that disagrees.

 It cannot read prose. "four of which are locked" is a sentence, not a number,
 and a regular expression that tried to understand it would give false comfort
 -- so the sentences that state a rule are listed explicitly as FORBIDDEN
 phrases, and each is tied to the constant that makes it false.
===============================================================================
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HDR = ROOT / "src" / "wam" / "wam-params.h"

RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"

# Everything a stranger can read. Build output and dependencies are excluded:
# they are copies of a moment, not claims we are making now.
PUBLISHED = [
    "README.md", "WHITEPAPER.md", "SECURITY.md", "PROGRESS.md",
    "docs/*.md", "posts/*.txt", "integration/*/PR.md",
    "site/*.html", "explorer/web/index.html", "out/*.html",
]

EXCLUDE_DIRS = ("build/", "node_modules/", ".git/", "depends/", "src/")


def authority() -> dict:
    """Read the constants the network actually enforces."""
    text = HDR.read_text(encoding="utf-8")

    def const(name, cast=int):
        m = re.search(rf"{name}\s*=\s*([^;]+);", text)
        if not m:
            return None
        raw = m.group(1).replace("'", "").strip()
        mul = re.match(r"([\d]+)\s*\*\s*WAM_COIN", raw)
        if mul:
            return cast(mul.group(1))
        m2 = re.match(r"(0x[0-9A-Fa-f]+|\d+)", raw)
        return cast(m2.group(1), 0) if (m2 and m2.group(1).startswith("0x")) \
            else (cast(m2.group(1)) if m2 else None)

    m = re.search(r"WAM_PREMINE_UNLOCK_TIMES\[[^\]]*\]\s*=\s*\{(.*?)\}", text, re.S)
    unlocks = [int(v) for v in re.findall(r"\b\d{9,}\b", m.group(1))] if m else []

    return {
        "max_money":      const("WAM_MAX_MONEY"),
        "premine":        const("WAM_GENESIS_PREMINE"),
        "mining":         const("WAM_MINING_ALLOCATION"),
        "subsidy":        const("WAM_INITIAL_BLOCK_SUBSIDY"),
        "halving":        const("WAM_SUBSIDY_HALVING_INTERVAL"),
        "devfee_pct":     const("WAM_DEVFEE_PERCENT"),
        "devfee_last":    const("WAM_DEVFEE_LAST_HEIGHT"),
        "spacing":        const("WAM_POW_TARGET_SPACING"),
        "maturity":       const("WAM_COINBASE_MATURITY"),
        "epoch":          const("WAM_RANDOMX_EPOCH_BLOCKS"),
        "epoch_lag":      const("WAM_RANDOMX_EPOCH_LAG"),
        "tranches":       const("WAM_PREMINE_TRANCHES"),
        "tranche_amount": const("WAM_PREMINE_TRANCHE_AMOUNT"),
        "p2p_main":       const("WAM_MAINNET_P2P_PORT"),
        "rpc_main":       const("WAM_MAINNET_RPC_PORT"),
        "p2p_test":       const("WAM_TESTNET_P2P_PORT"),
        "unlocks":        unlocks,
    }


def files():
    seen = []
    for pat in PUBLISHED:
        for p in sorted(ROOT.glob(pat)):
            rel = p.relative_to(ROOT).as_posix()
            if any(rel.startswith(d) for d in EXCLUDE_DIRS):
                continue
            if p.is_file() and rel not in seen:
                seen.append(rel)
    return seen


def main() -> int:
    a = authority()
    fails, warns = [], []

    def bad(m): fails.append(m)
    def warn(m): warns.append(m)

    # ---- 1. dates that are stated but not enforced -------------------------
    #
    # The exact failure the founder found. Any yyyy-09-15 written next to a
    # tranche must be one the header actually locks to.
    import datetime
    enforced = {datetime.datetime.utcfromtimestamp(t).strftime("%Y-%m-%d")
                for t in a["unlocks"]}
    launch_day = "2026-09-15"

    for rel in files():
        text = (ROOT / rel).read_text(encoding="utf-8", errors="replace")
        for i, line in enumerate(text.splitlines(), 1):
            # A line that talks about a tranche, an unlock or 400,000 coins and
            # also carries a date.
            if not re.search(r"400[,']?000|tranche|unlock|شريحة|يفتح", line, re.I):
                continue
            for d in re.findall(r"\b(20\d\d-\d\d-\d\d)\b", line):
                if d in enforced:
                    continue
                if d == launch_day:
                    bad(f"{rel}:{i} says a tranche unlocks on LAUNCH DAY "
                        f"({launch_day}). Consensus locks every tranche; the "
                        f"earliest is {sorted(enforced)[0]}.")
                else:
                    bad(f"{rel}:{i} states an unlock date {d} that consensus "
                        f"does not enforce. Enforced: {', '.join(sorted(enforced))}")

    # ---- 2. sentences that state a rule the code contradicts ---------------
    #
    # Prose cannot be parsed, so the sentences that make a factual claim are
    # named. Each is here because it was true once.
    FORBIDDEN = [
        (r"four of which are locked",
         "every tranche is locked; none is liquid at launch"),
        (r"\bfour\b[^.\n]{0,40}\blocked behind\b",
         "every tranche is locked; none is liquid at launch"),
        (r"أربع(ة)? منها مقفول",
         "الخمس كلّها مقفولة"),
        (r"first tranche[^.\n]{0,60}(liquid|spendable|available)[^.\n]{0,30}launch",
         "no tranche is spendable at launch"),
    ]
    for rel in files():
        text = (ROOT / rel).read_text(encoding="utf-8", errors="replace")
        for i, line in enumerate(text.splitlines(), 1):
            for pat, truth in FORBIDDEN:
                if re.search(pat, line, re.I):
                    bad(f"{rel}:{i} claims something consensus denies -- {truth}")

    # ---- 3. numbers that must match the header exactly ---------------------
    # ---- 3. numbers stated as facts, checked against the header ------------
    #
    # These patterns match the CLAIM, and capture whatever number the document
    # put there. The first version matched the correct value instead -- it
    # searched for "22,000,000" -- so a whitepaper saying the cap was 23,000,000
    # simply did not match anything and passed in silence. A check built that
    # way can only ever confirm what is right; it cannot contradict what is
    # wrong, which is the only job it has. Proved by editing the cap and
    # watching it say ok.
    #
    # "halving in 196,086 blocks" is a countdown, not the interval, so the
    # halving patterns only match a value stated AS the interval. A warning
    # that is permanently wrong teaches a reader to skip warnings.
    CLAIMS = [
        (r"(?:hard|maximum|max)\s+(?:supply\s+)?(?:ceiling\s+|cap\s+)?"
         r"(?:of\s+)?\*{0,2}([\d,']{6,12})\*{0,2}",   a["max_money"], "supply cap"),
        (r"([\d,']{6,12})\s*WAM\**\s*\|?\s*(?:hard[- ])?cap",  a["max_money"], "supply cap"),
        (r"maximum supply[^|\n]*\|\s*\*{0,2}([\d,']{6,12})",   a["max_money"], "supply cap"),
        # Tight, because loose does not work here. "2,000,000 premine +
        # 20,000,000 mined = 22,000,000" is a correct sentence, and a pattern
        # that took the first number within forty characters of the word read
        # the 20,000,000 out of it and called the whitepaper wrong. A check
        # that cries about correct prose gets switched off, and then the one
        # real finding arrives inside noise nobody reads.
        (r"([\d,']{7,12})\s*(?:WAM\s+)?(?:premine|founder reserve)\b", a["premine"], "premine"),
        (r"(?:premine|founder reserve)\s*(?:of|is|:|\|)\s*\*{0,2}([\d,']{7,12})",
         a["premine"], "premine"),
        (r"\bevery\s+([\d,']{6,9})\s+blocks\b",           a["halving"], "halving interval"),
        (r"halving interval[^\d\n]{0,20}([\d,']{6,9})",   a["halving"], "halving interval"),
        (r"(?:expires?|ends?)\s+at\s+(?:block\s+|height\s+)([\d,']{6,9})",
         a["devfee_last"], "treasury end height"),
        # Two forms, because most of these facts live in a markdown table and
        # the value sits on the far side of a pipe. The prose-only pattern
        # excluded "|" to stop it running into the next cell, and so could
        # never match "| Block time | 120 seconds |" -- the exact row a reader
        # looks at. Caught by deliberately writing 60 seconds and watching the
        # check say ok.
        (r"block time[^|\n]{0,20}?([\d,']{2,4})\s*(?:s\b|second)", a["spacing"], "block time"),
        (r"block time\s*\|\s*\*{0,2}([\d,']{2,4})\s*(?:s\b|second)", a["spacing"], "block time"),
        (r"(?:initial )?(?:block )?subsidy\s*\|\s*\*{0,2}([\d,']{1,4})\s*WAM",
         a["subsidy"], "initial subsidy"),
        (r"halving\s*\|\s*\*{0,2}every\s+([\d,']{6,9})", a["halving"], "halving interval"),
        (r"coinbase maturity[^\d\n]{0,20}([\d,']{2,4})", a["maturity"], "coinbase maturity"),
        (r"([\d,']{2,4})[- ]block coinbase maturity",    a["maturity"], "coinbase maturity"),
        (r"tranche[^|\n]{0,20}?([\d,']{6,8})\s*WAM",     a["tranche_amount"], "tranche amount"),
    ]
    for rel in files():
        text = (ROOT / rel).read_text(encoding="utf-8", errors="replace")
        for i, line in enumerate(text.splitlines(), 1):
            for pat, want, label in CLAIMS:
                if want is None:
                    continue
                for m in re.finditer(pat, line, re.I):
                    try:
                        got = int(re.sub(r"[,']", "", m.group(1)))
                    except (ValueError, IndexError):
                        continue
                    if got != want:
                        bad(f"{rel}:{i} states the {label} as {got:,}; the "
                            f"network enforces {want:,}")

    # ---- report ------------------------------------------------------------
    print()
    print(f"{BLD}what we publish, against what the chain enforces{OFF}")
    print(f"  authority : {HDR.relative_to(ROOT)}")
    print(f"  documents : {len(files())} published file(s)")
    print(f"  enforced unlocks: {', '.join(sorted(enforced))}")
    print()

    for m in fails:
        print(f"  {RED}FAIL{OFF}  {m}")
    for m in warns:
        print(f"  {YEL}!!{OFF}    {m}")

    print()
    if fails:
        print(f"  {RED}{len(fails)} published claim(s) the network does not "
              f"enforce{OFF}")
    elif warns:
        print(f"  {YEL}nothing false; {len(warns)} number(s) worth a human "
              f"reading{OFF}")
    else:
        print(f"  {GRN}every published number matches the rule the network "
              f"enforces{OFF}")
    print()
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

# WAM Coin — roadmap from repository to living network

**Read this first, honestly:** the code is the easy part, and it is already mostly done.
Almost every proof-of-work launch that fails does so for reasons no amount of C++ fixes.
This document is organised around that fact — the technical phases are short, and the
phases about people, liquidity and trust are long.

Nobody can plan a coin into market leadership, and this document does not pretend to. What
a plan *can* do is remove the failure modes that are within your control, and there are
more of those than most projects admit.

---

## Phase 0 — make it compile *(blocking everything; 1–2 weeks)*

Nothing below matters until this is done. **2,792 lines of C++ have never seen a
compiler.**

| # | Task | Gate |
|---|---|---|
| 0.1 | Provision Ubuntu 22.04 or 24.04, 8 GB RAM, 40 GB disk | `ssh` works |
| 0.2 | `./install.sh --network regtest` | binaries exist |
| 0.3 | **Fix the patch anchors** (expect 2–5 misses of 12) | patcher runs clean |
| 0.4 | Link librandomx, resolve compile errors in `src/wam/` | `make` succeeds |
| 0.5 | `test_bitcoin --run_test=wam_monetary_tests,wam_devfee_tests` | all green |
| 0.6 | `wamd -regtest` starts, `getsupplyinfo` answers | node alive |

**Exit gate:** a regtest node that mines blocks and reports a correct supply.

> Step 0.3 is the real work. See PROGRESS.md — never loosen an anchor to make it apply.

---

## Phase 1 — prove the four dangerous claims *(1 week)*

These are the four things that are **unfixable after mainnet launch**. Each must be
observed failing and succeeding, not assumed.

| Claim | How to prove it |
|---|---|
| The premine is spendable at all | Spend tranche 1 on regtest after 100 confirmations. If change WAM-005 did not apply, the entire 2,000,000 is burned — and you find out here or never. |
| The vesting locks actually lock | Attempt to spend tranche 2. The node must refuse. **A lock you have not seen refuse a spend is a lock you do not have.** |
| The 5% is enforced, not requested | Hand-craft a block with no treasury output. The node must reject it with `bad-cb-devfee-amount`. |
| The fee really expires | On a throwaway chain with a lowered `WAM_DEVFEE_LAST_HEIGHT`, mine past it and confirm a block with no treasury output is *accepted*. |

**Exit gate:** all four demonstrated, with terminal output saved.

---

## Phase 2 — testnet *(4–6 weeks, do not compress this)*

| # | Task | Why |
|---|---|---|
| 2.1 | Generate a **testnet** founder key, mine testnet genesis | rehearse the mainnet ritual with nothing at stake |
| 2.2 | Run 3 nodes on 3 different providers | proves P2P actually works between strangers |
| 2.3 | Point a real CPU miner (xmrig) at the stratum pool | **the stratum has never met a miner** |
| 2.4 | Run a full pool payment cycle end to end | share → block → maturity → `sendmany` |
| 2.5 | Simulate an orphaned block | confirm nobody is paid for it |
| 2.6 | **Cross at least two RandomX epoch rotations** | testnet epochs are 256 blocks (~8h) for exactly this |
| 2.7 | Point 20× hashrate at it for an hour, then remove it | proves DGWv3 absorbs and recovers |
| 2.8 | Write functional tests for the WAM rules | none exist yet; regressions are invisible without them |

**Exit gate:** two uninterrupted weeks, ≥2 epoch rotations, zero forks, zero payment
discrepancies.

> A shortened testnet is the most common cause of a dead mainnet. Nothing on this list is
> optional.

---

## Phase 3 — infrastructure & the things money cannot fix later *(parallel with Phase 2)*

| # | Task | Note |
|---|---|---|
| 3.1 | Register `wamcoin.org` | it is hardcoded in `chainparams.cpp` and does not exist |
| 3.2 | Stand up 3 DNS seed nodes on **3 different ASNs** | one provider = one partition away from a dead network |
| 3.3 | Register a SLIP-44 coin type | needed before any hardware wallet will ever support you |
| 3.4 | **Independent security audit of the WAM diff** | ~2,800 lines; this is affordable and it is the single strongest trust signal a small chain can buy |
| 3.5 | **Legal review in your jurisdiction** | issuing a token has real regulatory exposure; exchanges will ask, and "we didn't check" ends listings |
| 3.6 | Multi-sig custody for the treasury | a single key holding 12.50% is a standing liability |
| 3.7 | Reproducible builds + signed release binaries | users must not have to trust your laptop |
| 3.8 | Public block explorer (fuller than `explorer/`) | the current one is a monitor, not a full explorer |

---

## Phase 4 — launch *(the day itself)*

Work `docs/LAUNCH_CHECKLIST.md` top to bottom. Do not skip Phase 5 of it — spending the
premine on a private chain — even though by then you will be sure it works.

Announce the genesis hash, merkle root, treasury address and vesting schedule **before**
the first block, so anyone can verify what they were promised against what shipped.

---

## Phase 5 — the part that actually decides whether WAM survives

Everything above is engineering, and engineering is the part you control. What follows is
not a guarantee of anything. It is the honest list of what separates chains that are alive
in three years from the thousands that are not.

### 0. Value does not arrive before the hashrate that defends it

Decided by the founder on 6 September 2026, against an earlier idea of his own:
giving WAM a price from day one by accepting it across the companies he owns.

He worked out why not, and he is right. A proof-of-work chain's entire security
budget is its hashrate. An attacker performs one calculation -- does what I gain
exceed what it costs to out-hash the network -- and value arrives instantly
while hashrate arrives slowly. In between there is a window where the coin is
worth taking and not worth defending, and that window is where small chains
die. Not theory: it is how most 51% attacks on small coins have happened, and
nearly all of them followed a listing.

Measured on the day the decision was made:

<!-- wam:quote-begin -->
    the whole test network      5,446 - 6,089 H/s
    one ordinary desktop        8,740 H/s  (8 threads, measured)
<!-- wam:quote-end -->

The network is weaker than a single desktop computer. Out-hashing it for six
hours costs less than ten dollars of rented CPU. That is not a defect and it is
not unusual -- it is what every chain looks like on its first day. It becomes a
defect only if something valuable is put behind it first.

So: no manufactured demand, no company acceptance, no artificial price, until
the cost of attacking the chain is large next to whatever is being placed on
it. The rule is a comparison and not a feeling --

  **what we put on the chain stays below what an attack on it costs**

-- and it is meant to be checked with a number before any decision to widen
use, not argued about afterwards.

What holds the line meanwhile is confirmation depth. A reorg 60 blocks deep
costs sixty times a reorg one block deep, which is why the published guidance
is 20 confirmations wallet-to-wallet and 60 for an exchange deposit. When WAM
is eventually accepted anywhere, the depth required rises with the amount.

Value earned by mining brings its own defence with it. Value granted by us
arrives alone.

### 1. Answer "why does this exist?" in one sentence — and mean it

Right now WAM's differentiators are: a hard 22M cap, CPU-mineable, 2-minute blocks, and a
founder allocation that is bounded and verifiable. **That is a positioning, not yet a
reason to exist.** Monero already owns "CPU-mineable"; Bitcoin owns "hard cap".

The strongest honest angle available to you is the one already built into the code:
**every promise is machine-checkable.** The vesting is in the genesis script, not a PDF.
The fee expiry is a consensus rule, not a pledge. Very few projects can say that, and it
is provable rather than claimed. Lead with it.

If you cannot articulate a use case beyond "it is a coin", the launch will be technically
perfect and commercially irrelevant. That question deserves more of your time than any
remaining line of C++.

### 2. Miners before speculators

A chain with no hashrate is not a chain. Before launch, have **specific people** committed
to pointing CPUs at it on day one — not an audience, individuals you have spoken to. Ten
committed miners beat ten thousand impressions.

### 3. Publish the uncomfortable numbers yourself

12.50% founder allocation. Nothing liquid at launch. §8 of the whitepaper, unedited. If a <!-- wam:quote-line -->
critic discovers a number you presented gently, you lose the argument permanently. If you
published it first, you win it permanently. **This is the cheapest credibility available
and most projects refuse to buy it.**

### 4. Ship on a public cadence, forever

The most reliable predictor of a dead chain is a repository whose last commit is three
months after launch. Weekly notes, monthly releases, a public treasury spending report.
The consensus layer enforces that the 5% is *collected*; only disclosure shows what it was
*used for*, and that gap is where trust is won or lost.

### 5. Track upstream Bitcoin Core security releases

WAM inherits Core's codebase and its vulnerabilities. A fork that stops merging upstream
fixes becomes dangerous over time. Subscribe to the security announcements and treat a
Core CVE as a WAM CVE until proven otherwise.

### 6. Listings come after liquidity, not before

Exchanges list what people already trade. Chasing a listing before there is organic volume
burns money for a chart nobody looks at. Earn the volume first.

**Status, 2026-08-18.** Enquiries have been sent to six decentralised venues asking what
they require in order to list: Komodo Wallet, BasicSwap DEX, Bisq, Maya Protocol, Haveno and
Block DX. They are the right category for this chain — every one settles native assets by
atomic swap or peer-to-peer order book, so none needs a bridge, a wrapped token or a smart
contract, and none asks the founder to supply liquidity. WAM cannot be listed on an
AMM-style DEX at all: it is its own layer 1, not a token on someone else's chain, which is
the same reason Monero is not on Uniswap.

**None of them has agreed to anything.** These are requests for their requirements, and
their answers are expected by email. Reviews at venues of this kind run two to three weeks,
which is why the enquiries went out before launch rather than after — not because anything
has been secured. It is recorded here as a step taken, and it stays worded this way until
one of them says yes.

The remaining gap is an Electrum server: Komodo Wallet requires one for UTXO chains, and it
is the only item on the common requirements list that WAM does not already have. `electrs`
is written for Bitcoin and WAM is RPC-compatible with it, so this is expected to be
configuration rather than new code.

### 7. Windows, and why it is a hashrate item rather than a convenience one

Every release so far is `x86_64-linux-gnu` and nothing else. `docs/START_HERE.md` said
builds for Windows and macOS were "planned", and until this line was written there was no
plan anywhere for a reader to check — which is a promise with nothing behind it, and it
is what prompted the question when it was finally asked out loud on 7 September.

This belongs beside §2 rather than in a list of niceties. RandomX was chosen so that an
ordinary desktop processor is competitive, and most ordinary desktop processors are inside
Windows machines. The measured hashrate on 6 September was about 6 kH/s — less than one
eight-thread desktop — and that, not the absence of a listing, is what a young chain dies
of. Requiring WSL filters out most of the people the algorithm was chosen for.

**Status, 7 September, measured.** The reason given here on the morning of the 7th was
that nobody had ever run the cross-build, so a signed binary would come from an
unexercised path. That reason is now void, and the sentence it justified has to be
re-argued on facts rather than left standing:

    ok    synced to height 6029 from genesis, over the real network
    ok    height 0 matches      ok    height 1 matches
    ok    height 5000 matches   ok    height 6000 matches
    every one of 4 blocks matches the running chain

A native `wamd.exe` -- 15 MB, `PE32+ x86-64` -- synced the test chain from genesis over
the real peer-to-peer protocol on Windows 11 and agreed with the Linux nodes block for
block, including block 1 where the treasury rule is first enforced. `check_isa_baseline.sh`
reads PE now and reports no AVX-512.

What that proves is narrow and worth stating exactly: RandomX cross-compiles for Windows
and computes the same proof-of-work, `depends` builds Core's dependencies for mingw, and
the consensus rules behave identically. It does not prove a release. Still open: the miner
is not built; `package_release.sh`, the checksum list and the signature have never covered
a second platform; and RandomX's own reference vectors have not been run on Windows, because
that test binary is dynamically linked and wants the mingw runtime DLLs.

**What the exercise found matters more than the binary.** Building for a second platform
surfaced three defects in a day, and one of them was launch-critical: setting
`nMinimumChainWork` turns on Core's presync path, which enforces Bitcoin's retarget
schedule, which DarkGravityWave violates at height 1 -- so no new node could sync. Every
published release carries zero there, so the live network was never affected; but
`check_min_chain_work.py` instructs setting it on mainnet after launch, which would have
stopped every newcomer syncing, in the weeks when newcomers are the entire point. That
was a trap with a date on it, and the date was after the 15th.

**First thing after the chain is stable**, in this order, because each step unblocks the
next:

1. `wamd` and `wam-cli` for Windows through `depends` with `HOST=x86_64-w64-mingw32`.
   This is what makes an address obtainable without WSL.
2. `wam-miner.exe`. One `g++` invocation and one static RandomX library — the smallest
   part of the work, and worthless before step 1.
3. macOS, which has the same shape and a smaller audience.

Until step 1 ships, WSL is the answer and the pages say so with the commands to do it,
rather than the word "planned".

---

## Realistic timeline

| Phase | Duration | Cumulative |
|---|---|---|
| 0 — compile | 1–2 weeks | 2 weeks |
| 1 — prove the four claims | 1 week | 3 weeks |
| 2 — testnet | 4–6 weeks | 9 weeks |
| 3 — infrastructure & audit | parallel, gated by 3.4/3.5 | 9–14 weeks |
| 4 — launch | 1 day | — |

**The 2026-09-15 launch date is ~6 weeks away and Phase 0 has not started.**

That is tight but not impossible — *if* Phase 0 begins now and the security audit and legal
review can run in parallel. If either slips, move the date. A date is one constant in one
header file; a rushed launch cannot be undone.

> If the date must move, change `WAM_GENESIS_TIME` in `src/wam/wam-params.h` **before** the
> genesis block is mined, and re-run the verification suite. Afterwards it is a hard fork.

---

## What this document deliberately does not contain

No price targets, no market-cap projections, no marketing spend plan, no promises about
returns. Those are not engineering questions, several of them are regulated advice, and a
roadmap that includes them is a roadmap you should not trust.

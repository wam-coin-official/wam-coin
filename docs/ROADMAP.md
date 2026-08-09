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
| 0.1 | Provision Ubuntu 22.04, 8 GB RAM, 40 GB disk | `ssh` works |
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

12.50% founder allocation. 1.82% liquid at launch. §8 of the whitepaper, unedited. If a
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

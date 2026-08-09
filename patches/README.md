# Changes to Bitcoin Core

This directory documents every departure WAM Coin makes from upstream Bitcoin Core v28.1.

**There are no `.patch` files here, and that is deliberate.**

A unified diff is pinned to line numbers and surrounding context. The moment upstream
touches a nearby line, the patch fails — and the usual response, bumping the fuzz factor
until it applies, is exactly how a consensus change silently lands in the wrong function.
For a codebase whose bugs cost real money, that trade is not acceptable.

Instead, `scripts/patch_upstream.py` applies **anchored transformations**:

- **`anchor`** — a string that must appear *exactly once* in the target file. Zero matches
  or two matches is a hard error, never a guess.
- **`marker`** — a string whose presence means the edit is already applied, so re-running
  is a no-op and a half-finished build can be resumed.
- **post-condition** — the marker is re-read from disk after writing.

Any surprise aborts the entire run before writing anything, because a partially patched
consensus layer is far more dangerous than an unpatched one.

```bash
python3 scripts/patch_upstream.py --list                          # what will change
python3 scripts/patch_upstream.py --tree build/wam-core --check    # dry run
```

---

## WAM-000 — Install the WAM source tree

Copies `src/wam/**` into the upstream tree and replaces `src/kernel/chainparams.cpp` and
`src/chainparamsseeds.h` with the WAM versions.

Not a consensus change in itself; it is what makes the rest possible.

---

## WAM-001 — Consensus parameters *(plumbing)*

Adds to `Consensus::Params`: `nInitialSubsidy`, `nGenesisPremine`, `nMaxMoney`,
`nDevFeePercent`, `nDevFeeStartHeight`, `devFeeAddress`, `nCoinbaseMaturity`,
`nDgwPastBlocks`, `nRandomXEpochBlocks`, `nRandomXEpochLag`.

Pure plumbing — these are the fields `chainparams.cpp` sets and the rest of the changes
read.

---

## WAM-002 — Hard cap of 22,000,000 WAM ⚠️ **consensus**

`src/consensus/amount.h`: `MAX_MONEY` 21,000,000 → 22,000,000.

`MoneyRange()` is Bitcoin's last line of defence against inflation bugs — the check that
catches an arithmetic error before it becomes money that should not exist. It has to match
the actual cap.

---

## WAM-003 — The WAM emission schedule ⚠️ **consensus**

`src/validation.cpp`: `GetBlockSubsidy()` delegates to `wam::GetBlockSubsidy()`.

Changes: 200,000-block halvings instead of 210,000, and height 0 mints the 2,000,000 WAM
premine.

The epoch index is computed from `(height − 1)`, not `height`. Using `height` directly, as
Bitcoin does, would place the genesis block inside epoch 0 and leave that epoch one block
short — which would silently break the 20,000,000 WAM arithmetic by 50 WAM.

The upstream function is kept as `GetBlockSubsidyUpstream()` for reference and marked
`[[maybe_unused]]`.

---

## WAM-004 — Consensus rule WAM-1: the mandatory treasury output ⚠️ **consensus**

`src/validation.cpp`, in `ConnectBlock`, checked **before** the coinbase value test.

> For every block at height between 1 and **400,000** inclusive, the coinbase MUST contain
> at least one output whose `scriptPubKey` is exactly the treasury script and whose value
> is ≥ 5% of the subsidy. Otherwise the block is invalid: `bad-cb-devfee-amount`.
> Outside that range the rule imposes nothing.

Without this, the 5% is a social convention that any miner can ignore at zero cost. With
it, ignoring it produces a block nobody accepts.

The upper bound (`WAM_DEVFEE_LAST_HEIGHT`) is what makes the fee a launch budget rather
than a perpetual tax: from block 400,001 miners keep 100% of the subsidy. Note that
`GetDevFeeAmount()` takes the height as a **mandatory** parameter with no default — when
the sunset was added, a defaulted argument would have let every existing call site keep
compiling while silently computing the pre-sunset amount.

Overpaying is allowed — pools that merge outputs, and anyone donating, must not be
penalised. Once the subsidy decays far enough that 5% truncates to zero, the rule stops
demanding an output rather than requiring a zero-value one that would only bloat the UTXO
set.

Tested in `src/wam/test/wam_devfee_tests.cpp`, including the subtle attack: paying the
correct *amount* to the wrong *script*.

---

## WAM-005 — Make the genesis premine spendable ⚠️ **consensus**

`src/validation.cpp`: add `AddCoins(view, *block.vtx[0], 0)` for the genesis block.

**This is the single most important change in the list.**

Stock Bitcoin Core never adds the genesis coinbase to the UTXO set. That is why Satoshi's
original 50 BTC are permanently unspendable — it is a quirk of the implementation, not a
policy. WAM mints the entire 2,000,000 WAM founder reserve in the genesis block, so without
this patch the premine would be **burned at launch, irrecoverably**.

`AddCoins` adds **all five** vesting tranches, not just the first. The four time-locked
outputs must exist in the UTXO set from block 0 even though `OP_CHECKLOCKTIMEVERIFY` will
refuse to let them move for years — a coin that is not in the set cannot later become
spendable.

All five remain subject to normal coinbase maturity as well: nothing moves until 100 blocks
exist on top of genesis.

**Verify this before mainnet.** Phase 5 of `docs/LAUNCH_CHECKLIST.md` requires actually
spending tranche 1 on a private chain, *and* confirming that tranches 2–5 refuse to be
spent. If this patch did not apply, that is where you find out — and there is no fix after
launch.

---

## WAM-006 — RandomX and DarkGravityWave v3 ⚠️ **consensus**

`src/pow.cpp`: `GetNextWorkRequired()` delegates to `wam::GetNextWorkRequired()`, and the
PoW comparison uses `wam::GetRandomXPoWHash()` instead of the header's double-SHA256.

**DGW v3** retargets on every block from a weighted average of the last 24 targets, with
the observed timespan clamped to ⅓×–3× the expected value. Bitcoin's 2,016-block retarget
would let a rented farm mine a week of blocks in an hour and then leave the chain frozen at
an unreachable difficulty. Chains have died this way.

**RandomX** keeps Bitcoin's 80-byte header and its double-SHA256 *block identifier* —
only the proof-of-work comparison changes. Block hashes, txids, the block index and every
RPC that reports a hash behave exactly as upstream.

Epoch 0 is keyed by `SHA256("WAM/RandomX/epoch-0/2026")` rather than the genesis hash,
because the latter would be circular: mining genesis needs a key, and that key would need
the hash mining is trying to produce.

---

## WAM-007 — Report the treasury amount in `getblocktemplate` *(RPC)*

`src/rpc/mining.cpp` adds to the GBT result:

```json
"devfee": { "amount": 250000000, "script": "76a914...88ac", "address": "W...", "percent": 5 },
"randomx_seedhash": "...",
"randomx_seedheight": 2048
```

Not consensus, but it is what lets a pool build a valid coinbase by copying one number
instead of reimplementing the emission schedule in a second language and being wrong about
it at some future halving.

The reference pool **refuses to start** if this field is absent.

---

## WAM-008 — Binary names *(packaging)*

`wamd`, `wam-cli`, `wam-tx`, `wam-util`. No consensus effect.

---

## Reviewing a change before you trust it

```bash
./scripts/fetch-upstream.sh
cd build/wam-core
diff -u src/validation.cpp.wam-orig src/validation.cpp
```

The patcher keeps a `.wam-orig` copy of every file it touches, so the real diff against
pristine upstream is always available — generated from the actual tree rather than from a
checked-in file that may have drifted.

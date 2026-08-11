# Running a WAM Coin mining pool

---

## Architecture

```
  miners ──stratum/TCP──▶ stratumServer ──▶ jobManager ──▶ daemon (wamd)
                               │                │              getblocktemplate
                               │                │              submitblock
                               │                └──▶ native/ (librandomx)
                               ▼                        share verification
                         shareProcessor ──▶ Redis
                               │                accounting, PPLNS window, balances
                               └──▶ apiServer ──▶ web dashboard
```

**jobManager** polls `getblocktemplate` every second, resolves the RandomX seed for the
height, and publishes a job. **stratumServer** fans it out. Every submitted share is
rebuilt from scratch — coinbase, merkle root, header — and hashed with RandomX on the libuv
threadpool. **shareProcessor** does the money.

---

## The two fees

These are constantly confused, so to be explicit:

| | Who sets it | How it is paid | Can the pool change it? |
|---|---|---|---|
| **5% treasury** | consensus rule WAM-1 | an output in the coinbase, created by the pool but *required* by the chain | **No.** A block without it is rejected. |
| **Pool fee** | you, in `config.json` | deducted from what the pool distributes | Yes, it is yours. |

The pool distributes `coinbasevalue − devfee.amount`. The treasury amount is read from the
`devfee` field that the patched daemon reports in `getblocktemplate` — the pool never
recomputes 5% itself, because that would mean duplicating the halving schedule in a second
language and being wrong about it at some future halving.

If `getblocktemplate` does not return `devfee`, the pool **refuses to build a template at
all**. An unpatched daemon would make it produce coinbases that consensus rejects with
`bad-cb-devfee-amount`, wasting every share submitted to it. Fix the daemon; never remove
this check.

`pool/test/rewards.test.js` includes a test that the reward calculator *throws* if handed
the raw coinbase value instead of the distributable value.

---

## Setup

```bash
cd pool
cp config.example.json config.json
$EDITOR config.json
npm install
npm run build:native
npm test
node server.js
```

### The settings that matter

```jsonc
"poolAddress": "W...",     // MUST start with W on mainnet. Checked at startup.
"rewardMode": "pplns",     // or "prop"
"poolFeePercent": 1.0,     // YOUR fee. Separate from the chain's 5%.
"pplnsMultiplier": 2,      // window = 2 x network difficulty
"minimumPayoutWam": 1.0,
"paymentIntervalSec": 600
```

`poolAddress` is validated against the network's version byte before anything else starts.
A testnet address on a mainnet pool would send every block reward into a void, so this
check is deliberately fatal rather than a warning.

---

## PPLNS vs PROP

**PROP** splits each block among the shares submitted since the previous block. Simple, and
easy to explain to miners — but it rewards pool hopping. A miner who mines only the early
part of each round earns above their fair share, and everyone else pays for it.

**PPLNS** splits each block among the last *N* units of difficulty submitted, ignoring round
boundaries. Leaving means forfeiting a share of every block found before your work ages out
of the window, so hopping stops being profitable. `N = pplnsMultiplier × network
difficulty`; 2 is the industry norm.

**The ordering rule that matters:** payouts are computed **at the moment the block is
found** and frozen into the pending-block record. They are *not* recomputed at maturity.
Recomputing 100 blocks later would use a share buffer that has completely turned over,
paying people who were not mining when the block was won. That is both unfair and, once
miners notice, fatal to a pool's reputation.

---

## Payment lifecycle

```
share ──▶ round hash + PPLNS list + hashrate ZSET
   │
block found ──▶ payouts computed and FROZEN ──▶ blocks:pending
   │
every 60s ──▶ getblock(hash)
   │              confirmations == -1  ──▶ blocks:orphaned, nobody is paid
   │              confirmations <  100 ──▶ stays pending
   │              confirmations >= 100 ──▶ balances credited, blocks:confirmed
   │
every 600s ──▶ balances >= minimumPayoutWam ──▶ sendmany ──▶ balances cleared
```

Balances are cleared **only after** `sendmany` returns a txid. Clearing them first would
lose every miner's money if the RPC failed.

A payment run is postponed entirely if the wallet cannot cover the full amount plus the fee
reserve. A partially failed batch is far harder to reconcile than a delayed one.

---

## Difficulty

Vardiff targets one share every 15 seconds per connection, measured over a sliding window,
and only retargets when the observed rate leaves a ±30% band. Retargeting on every share
would chase Poisson noise forever.

RandomX hashrates span four orders of magnitude — a phone at 200 H/s and a 64-core server
at 30 kH/s can be on the same pool — so three ports with different starting difficulties
are provided. Miners that never submit are also rescued by an idle check every 30 seconds.

Share difficulty uses the **RandomX diff-1 convention** (`2^256 / 2^32`), not Bitcoin's.
Using Bitcoin's constant would inflate every hashrate figure by ~4.3 billion.

---

## RandomX memory

| Mode | Memory | Use |
|---|---|---|
| light (`randomxFullMemory: false`) | ~256 MiB per live seed | **correct for a verifying pool** |
| full (`true`) | ~2.1 GiB per live seed | only if this process also mines |

Two seeds are kept alive at once. That is not a tuning knob: around an epoch boundary the
pool validates shares from the new epoch while stragglers from the old one are still
arriving, and holding exactly those two keeps memory bounded without thrashing.

Watch for the rotation warning in the log:

```
RandomX seed rotated: height 2048 -> 4096. Miners will rebuild their datasets;
expect a brief hashrate dip.
```

This is normal, happens every ~2.8 days, and lasts as long as your miners take to rebuild
2 GiB. The dashboard shows a countdown so it is never a surprise.

---

## Security

- **Never expose RPC port 9554.** `getblocktemplate` requires an unlocked node; anyone who
  reaches that port reaches the wallet.
- **Put the dashboard behind TLS** if it is public. It is read-only and accepts no bodies,
  but miner addresses are still visible.
- Keep the pool wallet separate from anything personal, holding only working balance.
- Set `exposeMinerIps: false` (the default). Miner IPs are not yours to publish.
- Back up `wallet.dat` and the Redis dump. Losing Redis means losing every unpaid balance;
  the chain has no record of who was owed what.
- The stratum port faces the open internet: sockets are capped in buffer size (16 KiB per
  line), message rate (240 per 10 s), and time-to-authorize (30 s). Connections producing
  persistent garbage are banned for 10 minutes.

---

## Monitoring

```bash
curl -s localhost:8080/api/health | jq
```

```json
{ "ok": true, "problems": [], "templateAgeSec": 3, "connections": 42, "uptimeSec": 84210 }
```

Alert on `ok: false`. The three conditions it reports are: no block template, a template
older than 120 seconds (the daemon is wedged or unreachable), and zero connected miners.

Other endpoints: `/api/stats`, `/api/blocks`, `/api/miners`, `/api/hashrate`,
`/api/payments`, `/api/miner?address=W...`, `/api/network`.

---

## Troubleshooting

**`getblocktemplate did not return a 'devfee' field`**
The daemon is not a patched `wamd`. Re-run `scripts/fetch-upstream.sh` and rebuild.

**`The WAM RandomX native addon is not built`**
`npm run build:native`, with `RANDOMX_INCLUDE` and `RANDOMX_LIB` pointing at
`build/randomx/src` and `build/randomx/build/librandomx.a`.

**Every share is rejected as low-difficulty**
Almost always a seed mismatch: the pool and the miner disagree about the RandomX key.
Compare `wam-cli getrandomxinfo` with the `mining.set_seedhash` value in the pool log.

**`payment run postponed: wallet holds ... but ... is due`**
Normal while blocks are maturing. Investigate only if it persists past 100 blocks after a
find.

**`config says network='mainnet' but wamd reports chain='test'`**
Exactly what it says. The pool refuses to start rather than mine to the wrong chain.

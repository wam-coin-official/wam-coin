# WAM Network Dashboard

Live monitoring for a WAM node: chain state, the supply against the 22,000,000 cap, the
founder vesting schedule, the treasury fee and its countdown, RandomX epoch rotation,
recent blocks, and a per-block treasury audit.

```bash
cd explorer
node server.js
# http://127.0.0.1:8081/
```

**Zero npm dependencies.** Node 18+ and nothing else — no `npm install`, no lockfile, no
build step. This is the page an operator opens when something is already broken, and
"npm install failed" is not an acceptable answer at that moment.

**Zero configuration in the normal case.** With no `config.json` the server reads
`rpcuser` / `rpcpassword` / network straight out of `~/.wam/wam.conf`, which `install.sh`
writes. Copy `config.example.json` to `config.json` only to override something.

---

## What it shows

| Panel | Why it is there |
|---|---|
| Height, hashrate, peers, mempool | Ordinary chain health. |
| **Supply vs. the 22,000,000 cap** | Split four ways: publicly mined, founder unlocked, founder time-locked, not yet mined. The premine is deliberately *not* counted as "mined" — doing so would overstate what miners produced. |
| **Founder vesting** | All five tranches with their unlock dates and live locked/unlocked status. |
| **Treasury fee** | Whether it is still collecting, and how many blocks until it expires at height 400,000. |
| **RandomX epoch** | Current seed and a countdown to the next rotation, so a hashrate dip is expected rather than alarming. |
| **Block audit** | Verifies any block against consensus rule WAM-1 and reports required vs. paid. |
| Recent blocks | Last 25, with age, size and difficulty. |

---

## Design decisions

**The browser never talks to wamd.** It talks to this server, which holds one cached
snapshot refreshed every 10 seconds. Ten open tabs cost the node exactly what one does, and
the RPC credentials never leave the machine.

**It starts even when the node is down.** Reporting that the node is unreachable *is* the
job. A dashboard that refuses to boot without a healthy backend is useless precisely when
you need it.

**A syncing node is flagged, loudly.** While `verificationprogress < 1` every figure on the
page describes the node's own tip, not the network head. A banner says so rather than
letting an operator read stale numbers as current ones.

**Every WAM-specific RPC is optional.** Pointed at a node built before `getsupplyinfo`,
`getdevfeeinfo` and `getrandomxinfo` existed — or at a stock `bitcoind` — the dashboard
shows less instead of crashing, and labels which numbers it recomputed itself.

**Node figures win over local ones.** When `getsupplyinfo` is available its answer is used,
because that number comes from consensus code. `lib/constants.js` is only a fallback, and
`scripts/verify_supply.py --check-constants` fails if it drifts from the C++ header.

**Nothing is written with `innerHTML`.** Block hashes and a peer's `subversion` string are
attacker-influenced; every wire value goes through `textContent`.

---

## API

All read-only, all `GET`.

| Endpoint | Returns |
|---|---|
| `/api/status` | The full snapshot: chain, supply, emission, treasury, randomx, mempool, peers, blocks. |
| `/api/blocks` | Recent blocks only. |
| `/api/search?q=` | Block height, block hash, or txid. |
| `/api/audit?block=` | Treasury compliance for one block. |
| `/api/health` | `200` + `{ok:true}` when the node is reachable, `503` otherwise. |

`/api/health` is the one to alert on:

```bash
curl -fs localhost:8081/api/health || echo "WAM node is down"
```

---

## Running it as a service

`install.sh` installs this unit automatically. To do it by hand:

```ini
[Unit]
Description=WAM Network Dashboard
After=network-online.target wamd.service

[Service]
Type=simple
User=wam
WorkingDirectory=/opt/wam-blockchain-core/explorer
ExecStart=/usr/bin/node /opt/wam-blockchain-core/explorer/server.js
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
```

---

## Exposing it publicly

The default bind is `127.0.0.1`. Before changing it:

- Put TLS in front (nginx / Caddy). The dashboard speaks plain HTTP by design.
- Never expose RPC port 9556 itself. `getblocktemplate` requires an unlocked node; anyone
  who reaches that port reaches the wallet.
- The dashboard exposes no private data and accepts no request bodies, but `/api/search`
  does pass queries through to the node — rate-limit it at the proxy.

---

## Troubleshooting

**`no RPC credentials found`**
Run `install.sh`, or copy `config.example.json` to `config.json` and fill in the password
from `~/.wam/wam.conf`.

**`wamd is not reachable at 127.0.0.1:9556`**
The node is not running, or is on another network's port (testnet 19556, regtest 29556).
`server.js` reads the port from `wam.conf` automatically — check that `testnet=1` /
`regtest=1` there matches the node you actually started.

**RandomX panel says "node lacks getrandomxinfo"**
The node was built without the WAM RPC commands. Re-run `scripts/fetch-upstream.sh` and
rebuild.

**Supply says "recomputed by the dashboard"**
Same cause. The figures are still correct — they come from the same constants — but they
are not coming from consensus code, so treat them as informational.

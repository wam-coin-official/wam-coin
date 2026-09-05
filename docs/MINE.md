# Mine WAM

Nine lines, no explanation. If you want the explanation, read
[START_HERE.md](START_HERE.md).

This page exists because a tester on 5 September said his friends "want plain
jane, step by step, and shortest way to start mining", and he was right that
the guide is the wrong shape for that. It explains what a blockchain is,
which that reader either knows already or does not care about.

Linux x86_64, about 2 GB of free memory. Nothing else.

## The test network — live now

```
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.7/wam-coin-v0.1.7-x86_64-linux-gnu.tar.gz
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.7/wam-miner-v0.1.7-x86_64-linux-gnu.tar.gz
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.7/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS
tar -xzf wam-coin-v0.1.7-x86_64-linux-gnu.tar.gz && tar -xzf wam-miner-v0.1.7-x86_64-linux-gnu.tar.gz
cd wam-coin-v0.1.7/bin
./wamd -testnet -daemon
./wam-cli -testnet createwallet "mine"
./wam-cli -testnet -rpcwallet=mine getnewaddress
```

The last command prints your address; it starts with `twam1`. Then, from
where the miner unpacked:

```
./wam-miner -o stratum+tcp://pool.wamcoin.org:3333 -u YOUR_ADDRESS -t 4
```

`-t 4` is how many processor cores to use. Without it the miner takes every
core but one, which makes the rest of the machine unpleasant to use.

## The one line that is not optional

```
sha256sum --ignore-missing -c SHA256SUMS
```

It should print `OK`. It costs a second, and it is the whole difference
between running our file and running whatever arrived instead. Every other
step here can be skipped and retried later; this one cannot be checked
afterwards.

## What you are mining

Test coins. They are worth nothing, they will not become real coins, and the
test chain is wiped whenever that is useful — it has been already. Mine here
to find what breaks before 15 September, not to earn.

## On 15 September, mainnet

The same commands without `-testnet`:

```
./wamd -daemon
./wam-cli createwallet "mine"
./wam-cli -rpcwallet=mine getnewaddress
./wam-miner -o stratum+tcp://pool.wamcoin.org:3333 -u YOUR_ADDRESS -t 4
```

Two things are **not** the same.

**Your testnet address will not work.** Make a new wallet. Testnet derives on
coin type 1 — SLIP-44 reserves it for every test chain, deliberately, so test
keys can never be confused with real ones — and WAM mainnet uses 5718349. The
prefixes differ too: `twam1` here, `wam1` there. The pool refuses a testnet
address on mainnet, so nothing is lost; it simply will not work.

**Do not assume today's download is the launch binary.** A release between
now and the 15th may change a consensus rule. v0.1.5 moved the mainnet
treasury address, and a node left on v0.1.4 would reject every valid block on
launch day and fork itself off the network at height 1 — silently, while
appearing to run perfectly. Subscribe so you are told:

github.com/wam-coin-official/wam-coin → **Watch ▾** → **Custom** →
**Releases** ✓

## When it does not work

**`dnsseed thread exit`, and nothing else happens.** You are on mainnet,
which is one block until 15 September, so the node is correctly fully synced
and stops looking for peers. Add `-testnet`.

**`incorrect password attempt` in the log.** There is no password. The node
writes `<datadir>/.cookie` at startup and clients read it, so `wam-cli` needs
the same `-testnet` and the same `-datadir=` as the daemon. A leftover
`wam.conf` carrying `rpcuser`/`rpcpassword` fights the cookie; delete those
two lines.

**`accepted` stays at 0.** Usually the wrong address format — it must start
with `twam1` on the test network.

**No block ever found.** Normal. One machine among many finds one rarely,
which is what the pool is for; your share of what the pool finds is paid to
your address anyway.

## Back up the wallet

```
./wam-cli -testnet -rpcwallet=mine backupwallet /path/you/choose/backup.dat
```

It prints nothing on success. Check the file exists and has a size — that is
the whole confirmation.

The live wallet is at `~/.wam/testnet3/wallets/mine/wallet.dat`, and
`listdescriptors true` prints the same keys in portable form. Treat that
output like cash: never paste it anywhere, including to us.

---

[discord](https://discord.gg/Gxvmrjy9Qb) ·
[explorer](https://explorer.wamcoin.org) ·
[pool](https://pool.wamcoin.org)

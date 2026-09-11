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
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.7/SHA256SUMS.asc
curl -LO https://raw.githubusercontent.com/wam-coin-official/wam-coin/main/scripts/verify_release.sh
curl -LO https://raw.githubusercontent.com/wam-coin-official/wam-coin/main/SIGNING-KEY.asc
bash verify_release.sh .
tar -xzf wam-coin-v0.1.7-x86_64-linux-gnu.tar.gz && tar -xzf wam-miner-v0.1.7-x86_64-linux-gnu.tar.gz
cd wam-coin-v0.1.7/bin
./wamd -testnet -daemon
./wam-cli -testnet createwallet "mine"
./wam-cli -testnet -rpcwallet=mine getnewaddress
```

> **Back it up before you do anything else.** One command, now, while there is
> nothing in it to lose:
>
> ```
> ./wam-cli -testnet -rpcwallet=mine backupwallet ~/wam-wallet-backup.dat
> ```
>
> This page says the same thing again further down, and on 6 September that was
> a hundred lines too late: somebody following it created a wallet, tidied his
> directory an hour later, and deleted the only copy. On testnet that costs
> nothing. The habit is what is being built here, and the person who builds it
> on 15 September has money in the file.

**If you restart the node and `wam-cli` answers `-18 Requested wallet does not
exist or is not loaded`,** the wallet is on disk and simply not open. Bitcoin
Core reopens the wallets it had open when it was last shut down cleanly; a
node stopped any other way, or started against a datadir that was cleared,
comes back with none.

```
./wam-cli -testnet listwallets           # what is open right now
ls ~/.wam/testnet3/wallets/              # what exists on disk
./wam-cli -testnet loadwallet "mine"     # open it again
```

Nothing is lost either way — `createwallet` writes a file and deleting
`blocks`, `chainstate` or `peers.dat` does not touch it. This was found on
6 September by somebody following this page, restarting his node three times,
and being told his wallet did not exist.

The last command prints your address; it starts with `twam1`. Then, from
where the miner unpacked:

```
./wam-miner -o stratum+tcp://pool.wamcoin.org:13333 -u YOUR_ADDRESS -t 4
```

**13333, not 3333.** The testnet pool moved off 3333-3336 on 11 September so
those ports stand empty for mainnet on the 15th. `pool.wamcoin.org:3333` is
the mainnet address and answers nothing until then -- pointing a testnet
miner at it now gets a connection refused, not a wrong chain, which is the
safer of the two ways to be wrong.

`-t 4` is how many processor cores to use. Without it the miner takes every
core but one, which makes the rest of the machine unpleasant to use.

## The one line that is not optional

```
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.7/SHA256SUMS.asc
curl -LO https://raw.githubusercontent.com/wam-coin-official/wam-coin/main/scripts/verify_release.sh
curl -LO https://raw.githubusercontent.com/wam-coin-official/wam-coin/main/SIGNING-KEY.asc
bash verify_release.sh .
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


## Your balance will say zero, and that is normal

The pool pays out at **1 WAM** and runs a payment round every **10 minutes**.
Below that threshold your earnings sit in the pool's ledger and not in your
wallet, so

```
./wam-cli -testnet -rpcwallet=mine getbalance
0.00000000
```

is what you will see for the first while, however hard the machine is
working. Nothing is missing and more threads is not the fix — it only raises
your share of each block the pool finds.

Watch the ledger instead of the wallet:

    https://pool.wamcoin.org

And if you change your payout address, your share history starts again from
nothing. Whatever the old address had earned stays owed to that address.

Written down on 6 September, after somebody mined for an hour, read
`0.00000000`, and reasonably concluded something was broken.


### And `getbalance` will DROP when you send to yourself

Send one coin from your own wallet to another address in the same wallet and
the balance goes down, not sideways. Nothing was lost. `getbalance` reports
only what is confirmed and spendable, and your change output is sitting in
the mempool until a block carries it.

`getbalance` is one number. `getbalances` is the truth:

```
./wam-cli -testnet -rpcwallet=mine getbalances
{
  "mine": {
    "trusted": 6.99973355,            confirmed, spendable now
    "untrusted_pending": 11.15475873, sent or received, not yet in a block
    "immature": 0.00000000            mined, waiting out the 100 blocks
  }
}
```

Use `getbalances` whenever a number surprises you. The three add up; one of
them alone never does.

Written down on 6 September because a miner sent a coin to himself, watched
the balance fall, and another miner — walkjivefly — explained it in the
channel before this project did.

## Back up the wallet

```
./wam-cli -testnet -rpcwallet=mine backupwallet /path/you/choose/backup.dat
```

It prints nothing on success. Check the file exists and has a size — that is
the whole confirmation.

The live wallet is at `~/.wam/testnet3/wallets/mine/wallet.dat`, and
`listdescriptors true` prints the same keys in portable form. Treat that
output like cash: never paste it anywhere, including to us.

## Restore it

A backup nobody has ever restored is a file you hope about. This page told you
how to make one in three separate places and never once said how to use one,
which was found on 8 September 2026 by the first person outside this project
to actually do it — onto a machine whose operating system he had reinstalled
that morning. These are his steps, not ours.

```
mkdir -p ~/.wam/testnet3/wallets/mine
cp /path/to/your/backup.dat ~/.wam/testnet3/wallets/mine/wallet.dat
./wam-cli -testnet loadwallet "mine"
./wam-cli -testnet -rpcwallet=mine getbalance
```

**The rename is the part that catches people.** Your backup may be called
anything you like, but the file inside the folder must be called `wallet.dat`,
and the folder must be named after the wallet you then pass to `loadwallet`.
Neither is guessable, and getting either wrong gives you an error about a
wallet that does not exist rather than one about a file that is misnamed.

His balance was simply there, with no rescan, because that node was syncing
from genesis: the blocks holding his coins arrived while the wallet was
already open. A node that finished syncing weeks ago is the other case, and
if the balance reads zero when you know it should not, ask the node to look
again:

```
./wam-cli -testnet -rpcwallet=mine rescanblockchain
```

It reads the chain from the beginning and takes as long as it takes.
`getwalletinfo` reports a `scanning` object while that is happening and
`false` when it is done, so you are never left guessing whether it is still
working.

---

[discord](https://discord.gg/Gxvmrjy9Qb) ·
[explorer](https://explorer.wamcoin.org) ·
[pool](https://pool.wamcoin.org)

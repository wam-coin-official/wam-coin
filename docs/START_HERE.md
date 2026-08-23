# Start here

**[بالعربية](START_HERE_AR.md)**

This page assumes you know nothing about cryptocurrency. If you already run a
node for another coin, skip to [Run a node](#3-run-a-node) — the commands are
what you expect, and the numbers you need are in the table at the end.

---

## 1. What is WAM, in plain words

WAM is money that no company issues and no bank holds.

There is a list of every payment ever made, and thousands of computers each
keep their own copy of that list. When you send WAM, your payment is announced
to all of them, they check it against their copies, and if it is valid they all
add it. Nobody can quietly change the list afterwards, because everyone else
still holds the version without your change.

That list is the *blockchain*. A computer keeping a copy is a *node*.

**Why anyone would bother:** nobody can freeze it, nobody needs your permission
to receive it, and nobody can print more than 22,000,000 of it — ever. That
number is not a promise. It is arithmetic every node checks on every block, and
a block that breaks it is thrown away by strangers who never heard of you.

**What makes WAM different from Bitcoin:** Bitcoin mining now needs specialised
machines that cost thousands. WAM uses an algorithm called *RandomX* that runs
best on the ordinary processor already in your laptop. The point is that
someone with one computer can take part, not only someone with a warehouse.

---

## 2. What you need

- A computer with Linux — a laptop is fine
- About 2 GB of free memory and 5 GB of disk
- An internet connection

That is all. No graphics card, no special hardware, no money to start.

> **Windows or Mac?** The current release is built for Linux. On Windows you
> can use WSL (Windows Subsystem for Linux), which gives you Linux inside
> Windows. Builds for Windows and macOS are planned but do not exist yet, and
> this page will not pretend otherwise.

---

## 3. Run a node

A node is a program that keeps a copy of the list and checks every payment on
it. It runs quietly in the background. You do not need one to own WAM, but
running one means you verify the rules yourself instead of trusting somebody
else's answer.

### Download it

```bash
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.5/wam-coin-v0.1.5-x86_64-linux-gnu.tar.gz
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.5/SHA256SUMS
```

### Check that it is really our file

```bash
sha256sum --ignore-missing -c SHA256SUMS
```

You should see `OK`. If you see `FAILED`, the download was corrupted or altered
— delete it and download again. **Do not skip this.** It costs one second and
it is the only thing standing between you and a file somebody else swapped in.

### Unpack and run

```bash
tar -xzf wam-coin-v0.1.5-x86_64-linux-gnu.tar.gz
cd wam-coin-v0.1.5/bin
./wamd -testnet -printtoconsole
```

The window will fill with lines. That is the node introducing itself to other
nodes and asking them for the list. Leave it running.

To watch it in another terminal:

```bash
./wam-cli -testnet getblockcount
```

That prints how many blocks you have. It should climb until it matches what
[explorer.wamcoin.org](https://explorer.wamcoin.org) shows.

> **Why `-testnet`?** Because the real network has not launched yet. See
> [section 7](#7-two-things-you-must-know).

---

## 4. Make yourself an address

An address is where WAM is sent, like an account number. It is free, you can
make as many as you like, and you do not register it with anyone.

```bash
./wam-cli -testnet createwallet "mine"
./wam-cli -testnet -rpcwallet=mine getnewaddress
```

You will get something like `twam1q4syaj2akkysnsymxm8g85whanz23v3jn0jm6dd`.
That is yours. Anyone can send to it; only you can spend from it.

> **The one rule that matters.** The file `wallet.dat` inside the node's folder
> holds the keys to your money. Copy it somewhere safe. If you lose it, the
> coins are gone — there is no support line, no password reset, and no one who
> can help. That is the same freedom that means nobody can freeze your money,
> seen from the other side.

---

## 5. Mine

Mining is your computer competing to be the one that adds the next block to the
list. Whoever adds it is paid for the work: **50 WAM**, of which 47.5 goes to
the miners and 2.5 to the project treasury for the first 400,000 blocks.

A single computer wins rarely, so miners join a **pool**: everybody works
together and the reward is split by how much work each contributed. Small,
steady payments instead of a lottery.

### Point your miner at the pool

```bash
./wam-miner -o stratum+tcp://pool.wamcoin.org:3333 -u YOUR_ADDRESS.rig1 -t 4
```

Replace `YOUR_ADDRESS` with the address from step 4. Keep the `.rig1` — it is
just a name for this machine, so you can tell your computers apart later.

`-t 4` is how many processor cores to use. Leave one or two free if you want
the computer to stay usable.

### Which port

| Port | For | Meaning |
|---|---|---|
| **3333** | a laptop or desktop | start here |
| 3334 | a server | fewer, larger reports |
| 3335 | a farm of machines | |

If you are not sure, use 3333. The pool adjusts to your speed by itself.

### What you will see

```
stats    3.41 kH/s   accepted 20  rejected 0  blocks 1
```

- **kH/s** — thousands of guesses per second. Your speed.
- **accepted** — proofs of work the pool took. This number going up means it
  is working.
- **rejected** — should stay near zero. If it climbs, your clock may be wrong:
  `sudo timedatectl set-ntp true`.
- **blocks** — blocks your machine found. This will be zero for a long while
  and that is normal.

---

## 6. What to expect

| | |
|---|---|
| A new block every | about 2 minutes |
| Paid per block | 50 WAM (47.5 to miners) |
| Halves every | 200,000 blocks — roughly 15 months |
| Ever created, at most | 22,000,000 WAM |
| Rewards become spendable after | 100 blocks — about 3 hours |

That last row surprises people. A mining reward is frozen for 100 blocks before
it can be spent. Every coin that works this way does the same thing, for a
reason: it prevents money being spent out of a block that later turns out not
to belong on the list.

---

## 7. Two things you must know

**The real network has not launched.** It launches **15 September 2026**.
Everything above connects you to the *test network*, which exists so people can
practise and so faults are found before real money is involved.

**Test coins are worth nothing.** They cannot be sold, they will not become
real coins, and the test network is wiped and restarted whenever that is
useful — it has been already. Mine there to learn and to help, not to earn.

When mainnet launches, the same commands work without `-testnet`.

---

## 8. When something goes wrong

**The node prints errors and stops.**
Read the last line before it stopped; it usually says exactly what it needs. If
it mentions an address already in use, another copy is already running.

**`getblockcount` says 0 and stays there.**
Your node found no one to talk to. Check that your internet works, and wait two
minutes — it retries by itself.

**The miner says "cannot connect".**
Check the pool address for typing mistakes. Some networks block unusual ports;
try from a different connection.

**The miner runs but `accepted` stays at 0.**
Usually the wrong address format. It must start with `twam1` on the test
network — a mainnet address will be refused.

**Everything looks fine and I have never found a block.**
That is normal. One machine among many finds one rarely; that is what the pool
is for, and your share of what the pool finds is paid to your address anyway.

---

## 9. The numbers, for anyone who wants them

| | Mainnet | Testnet |
|---|---|---|
| Peer port | 9555 | 19555 |
| RPC port | 9554 | 19554 |
| Addresses start with | `W`, `w`, `wam1` | `T`, `t`, `twam1` |
| Genesis block | `d8d3debe…` | `ce81c20a…` |

Proof of work is RandomX over Bitcoin's 80-byte header. Everything else — the
transaction format, the script language, SegWit, PSBT — is Bitcoin Core v28.1,
because 250,000 lines that have been attacked for fifteen years are safer than
anything rewritten from scratch.

---

## Where to go next

- **[The whitepaper](../WHITEPAPER.md)** — why the money works the way it does
- **[Build it yourself](BUILD.md)** — compile from source rather than trusting
  a download
- **[Run a pool](POOL_OPERATOR.md)** — if you want to host one for others
- **[explorer.wamcoin.org](https://explorer.wamcoin.org)** — look at the chain
  without running anything

Questions: `wam.coin.official@proton.me`

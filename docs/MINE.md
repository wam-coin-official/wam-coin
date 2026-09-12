# Mine WAM

Nine lines, no explanation. If you want the explanation, read
[START_HERE.md](START_HERE.md).

This page exists because a tester on 5 September said his friends "want plain
jane, step by step, and shortest way to start mining", and he was right that
the guide is the wrong shape for that. It explains what a blockchain is,
which that reader either knows already or does not care about.

Linux or Windows, 64-bit Intel or AMD, about 2 GB of free memory. Nothing
else. The Linux commands are first because they are the ones that have been
run by strangers since August; [Windows](#windows) is below them and is new in
v0.1.8 — including the antivirus warning you will get, which is explained
there rather than left to surprise you.

## The test network — live now

```
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.8/wam-coin-v0.1.8-x86_64-linux-gnu.tar.gz
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.8/wam-miner-v0.1.8-x86_64-linux-gnu.tar.gz
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.8/SHA256SUMS
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.8/SHA256SUMS.asc
curl -LO https://raw.githubusercontent.com/wam-coin-official/wam-coin/main/scripts/verify_release.sh
curl -LO https://raw.githubusercontent.com/wam-coin-official/wam-coin/main/SIGNING-KEY.asc
bash verify_release.sh .
tar -xzf wam-coin-v0.1.8-x86_64-linux-gnu.tar.gz && tar -xzf wam-miner-v0.1.8-x86_64-linux-gnu.tar.gz
cd wam-coin-v0.1.8/bin
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

## Windows

Since v0.1.8 there are Windows binaries, node and miner, and they need no WSL
and no Linux. Open PowerShell and work in a folder you choose:

```
mkdir C:\wam ; cd C:\wam
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.8/wam-coin-v0.1.8-x86_64-w64-mingw32.zip
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.8/wam-miner-v0.1.8-x86_64-w64-mingw32.zip
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.8/SHA256SUMS
Expand-Archive wam-coin-v0.1.8-x86_64-w64-mingw32.zip -DestinationPath .
Expand-Archive wam-miner-v0.1.8-x86_64-w64-mingw32.zip -DestinationPath .
```

**Check it before you run it.** One command, and it is the only step here that
cannot be checked afterwards:

```
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.8/SHA256SUMS.asc
curl -LO https://raw.githubusercontent.com/wam-coin-official/wam-coin/main/SIGNING-KEY.asc
curl -LO https://raw.githubusercontent.com/wam-coin-official/wam-coin/main/scripts/verify_release.ps1
powershell -ExecutionPolicy Bypass -File verify_release.ps1
```

It should end with `this is the WAM release, unmodified since it was signed`.
Anything else, and it will say what is wrong and tell you not to run the
files.

This page used to tell you to run `certutil -hashfile` and compare
sixty-four hexadecimal characters against `SHA256SUMS` by eye. Nobody does
that: people check the first four characters and the last four, which is the
check an attacker would design for. The script compares every one of them,
and then does the part `certutil` cannot — it verifies that `SHA256SUMS`
itself is ours, by the fingerprint published in
[SECURITY.md](../SECURITY.md).

That last part needs GnuPG, which Windows does not ship. If you have
[Git for Windows](https://gitforwindows.org/) you already have one and the
script finds it; otherwise install [Gpg4win](https://gpg4win.org/). Without
it the script checks the hashes, tells you the signature was **not** checked,
and exits without saying the release is good — because a matching hash
against an unsigned list proves your download is not corrupt and proves
nothing about who wrote the list.

Then the node, with the directory named explicitly so you always know where
the wallet is:

```
cd wam-coin-v0.1.8\bin
.\wamd.exe -testnet -datadir=C:\wam\data -daemon
.\wam-cli.exe -testnet -datadir=C:\wam\data createwallet "mine"
.\wam-cli.exe -testnet -datadir=C:\wam\data -rpcwallet=mine backupwallet C:\wam\wallet-backup.dat
.\wam-cli.exe -testnet -datadir=C:\wam\data -rpcwallet=mine getnewaddress
```

and the miner, from the folder it unpacked into:

```
.\wam-miner.exe -o stratum+tcp://pool.wamcoin.org:13333 -u YOUR_ADDRESS -t 4
```

### Windows will call the miner a virus, and it is wrong

This is the part nobody tells you, so it is written here before it happens to
you. On 12 September, the first time the Windows miner was run on a real
desktop, it passed every self-test, connected to the pool, took a job, and
started hashing. Fourteen seconds later Windows Defender killed the process
and deleted the file:

```
Trojan:Win32/Bearfoos.A!ml        Severity: Severe
```

`!ml` means a machine-learning guess, and `Bearfoos.A` is a generic label. The
reason is not subtle: a program that opens a network connection and then uses
every processor core is behaving exactly like the cryptojacking malware that
does this to people without asking. No scanner can tell them apart by
behaviour, because the behaviour is identical. The difference is consent — you
chose to run it, and it mines to the address on its own command line and
nowhere else.

The thing that removes the warning is a publisher certificate, which costs
money and a registered company, and this project has neither yet. So:

1. **Verify the file instead of trusting a verdict.** The SHA256 above and the
   signature on `SHA256SUMS` are evidence that these are the bytes we built.
   An antivirus verdict is an opinion about behaviour.
2. **If you want to mine, allow that one file**, by name — Windows Security →
   Virus & threat protection → Manage settings → Exclusions → Add → File, and
   pick `wam-miner.exe`. Not a folder. Not the whole machine. Turning your
   antivirus off to run a stranger's program is how people actually get
   robbed, and anyone telling you to do that is not us.
3. **Or do not mine, and run the node anyway.** `wamd.exe` is not a miner and
   is not normally flagged. A node that relays blocks and holds a wallet is a
   real contribution and costs you no CPU.

The node's own first run may show a blue SmartScreen box saying "Windows
protected your PC" — that is the unsigned-publisher notice, not a virus
report. `More info` → `Run anyway`, once you have checked the hash.

## The one line that is not optional

```
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.8/SHA256SUMS.asc
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

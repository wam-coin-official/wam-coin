# Launch day — the order things happen in

**2026-09-15 00:00 UTC.**

`LAUNCH_CHECKLIST.md` is the list of things that must be *true*. This is the
list of things that must be *done*, in the order they must be done in, by
someone who has not slept and should not be deciding anything at midnight.

Read it now, not then. Print it if you can.

---

## The one sentence that matters

**Everything is recoverable until block 1 exists. Nothing is recoverable
afterwards.**

Genesis on its own commits you to nothing: it is data in a binary, and if
something is wrong you stop, fix it, and start again with nobody harmed.
The moment a block is mined on top of it and one other node has seen it, the
chain is real and its rules are fixed forever.

Everything below is arranged around that line. Phases A to C sit before it.
Phase D crosses it.

---

## Before the day — not on it

None of this is done at midnight.

| | |
|---|---|
| The third seed exists | three hostnames on **three providers**, not three names on two machines |
| Every machine already runs the release | `install_release.sh` has been run and the binaries are in place, unstarted on mainnet |
| Mainnet configs written | `wam.conf`, pool config, ElectrumX config — written, services **not** enabled |
| The pool's mainnet payout address is set | starts `wam1`, and it has been checked character by character |
| Backups verified | `wam-backup.sh --verify` on every host, within the day |
| The clock is right on every machine | `timedatectl` — genesis validation is absolute time, not relative |
| The paper matches the binary | the founder and treasury addresses in the release equal the ones on paper |

The last one is worth the minute it takes. A binary built from a checkout
that was not what you think it was is the failure that no later step catches.

```bash
wamd -version
strings $(command -v wamd) | grep -E '^W[a-zA-Z0-9]{25,34}$' | sort -u
```

---

## Phase A — before 00:00 UTC

Nothing here touches mainnet. All of it can be done hours early.

1. **Confirm the release is published and matches.**

   ```bash
   bash scripts/check_release_matches.sh
   ```

2. **Confirm every machine is on it and on `origin/main`.**

   ```bash
   bash scripts/check_deployed_code.sh <host1> <host2> <host3>
   ```

3. **Run the sweep, and read the SKIPPED lines.**

   ```bash
   bash scripts/sweep.sh --nodes "<host1> <host2> <host3>"
   ```

4. **Stop nothing.** Testnet keeps running through all of this. It is the
   only working system you have while mainnet is unproven.

---

## Phase B — the first mainnet node

Do this **after 00:00 UTC**. Not before, and the reason is sharper than it
looks.

### Why a mainnet node cannot be started early — rehearsed 2026-08-28

The obvious reason is that block 1's timestamp must be later than genesis,
so nothing can be mined until the date arrives. `MAX_FUTURE_BLOCK_TIME` is
two hours, and a block dated 15 September mined in August is rejected by
every node including your own.

The reason that is not obvious was found by trying it. A mainnet node
started before 15 September works **once**, from an empty datadir, and then
cannot start again:

```
The block database contains a block which appears to be from the future.
Please restart with -reindex or -reindex-chainstate to recover.
[error] Aborted block database rebuild. Exiting.
```

The block from the future is genesis. On a fresh datadir it is constructed
in memory and accepted; on every start afterwards it is read from disk and
the startup verification refuses a stored block dated ahead of now. Both
halves of this were tested on 28 August: empty datadir starts and reports
height 0, restart fails, every time.

So a mainnet node left running "ready" before launch is not ready. One
reboot and it is a crash-looping service with `Restart=always` hammering it,
and the operator finds out on the morning it mattered.

**The units exist on both hosts and are deliberately disabled.** On the day
they are started, not installed.

What *was* proved by rehearsing, and does not need repeating on the night:
genesis validates from nothing and its hash matches the assertion; the
supply is 2,000,000 with all five tranches locked; port 9555 is open through
both providers' firewalls; the DNS seeds answer with the mainnet nodes; and
the two nodes find each other without help.

5. **Start one node on mainnet.** One, not three.

   ```bash
   systemctl start wamd        # mainnet unit, not wamd-testnet
   journalctl -u wamd -f
   ```

6. **Genesis must be the hash you published.** This is the check the whole
   day rests on:

   ```bash
   wam-cli getblockhash 0
   # must equal the assertion in src/wam/chainparams.cpp
   ```

   If it does not match, **stop here**. Nothing has been mined. The chain
   does not exist yet and you have lost nothing but an hour.

7. **The money must be where you said it would be.**

   ```bash
   wam-cli getsupplyinfo
   # circulating              2,000,000
   # founder_vesting.unlocked 0
   # founder_vesting.locked   2,000,000
   ```

8. **The five premine outputs must exist and must be locked.**

   ```bash
   wam-cli getblock $(wam-cli getblockhash 0) 2
   # five outputs, every one a 32-byte scriptPubKey, none spendable today
   ```

**This is the last completely safe point.** Everything so far can be
abandoned with no consequence to anyone.

---

## Phase C — the other nodes

9. **Start node 2, then node 3.** Confirm each one finds the others and
   agrees on genesis before starting the next.

   ```bash
   wam-cli getconnectioncount
   wam-cli getblockhash 0        # on every host, the same hash
   ```

10. **Confirm the seeds answer with mainnet nodes.**

    ```bash
    bash scripts/check_dns_seeds.sh
    dig +short x9.seed1.wamcoin.org
    ```

11. **Confirm a stranger can sync from genesis**, from outside your
    machines:

    ```bash
    bash scripts/check_fresh_sync.sh --network mainnet --peer <host1>
    ```

---

## Phase D — the point of no return

Read the sentence at the top again before this step.

12. **Start mining.** The pool, or a single miner — it does not matter
    which, only that a block is produced.

13. **Block 1 must pay the treasury.** If it does not, the rule is not
    being enforced and you have just created a chain that does not do what
    the whitepaper says:

    ```bash
    wam-cli getdevfeeinfo "$(wam-cli getblockhash 1)"
    ```

14. **Blocks 1 to 30, every one of them.** Not a sample.

    ```bash
    for h in $(seq 1 30); do
        wam-cli getdevfeeinfo "$(wam-cli getblockhash $h)"
    done
    ```

15. **Confirm at least one other node has block 1.** A block only you have
    seen is not yet a chain.

---

## Phase E — the services people use

None of these can start before there is a chain for them to read.

16. **Electrum, on both hosts.** Same installer, different flag:

    ```bash
    bash integration/electrumx/install.sh --network mainnet
    ```

    Then, from somewhere else entirely:

    ```bash
    python3 scripts/check_electrum.py --node <host1> --network mainnet \
        electrum.wamcoin.org electrum2.wamcoin.org
    ```

17. **The pool.** Its payout address is mainnet and it must be checked
    before a single share is credited:

    ```bash
    python3 scripts/check_pool.py --node <host1> --network mainnet
    ```

18. **The explorer**, and confirm it publishes what consensus enforces:

    ```bash
    python3 scripts/check_explorer.py --node <host1> --network mainnet
    ```

---

## Phase F — telling people

Not before Phase D has passed. An announcement that precedes a verified
chain is a promise, and this project does not make those.

19. **Publish the facts anyone can check**: genesis hash, merkle root,
    treasury address, the height at which the treasury rule ends.

20. **Announce.** `bots/say.js` posts to both channels at once, in the right
    format for each:

    ```bash
    node bots/say.js --file launch.txt --dry-run   # read it
    node bots/say.js --file launch.txt
    ```

21. **The release for mainnet** — if a new version is cut for the day, its
    tag message is the release note and `scripts/consensus_floor.py` decides
    whether it needs a `MANDATORY:` line. The workflow refuses to publish a
    consensus change without one.

---

## What to do when something fails

| When | What it costs |
|---|---|
| Anything in Phase A or B | nothing. Stop, fix, start again. |
| Phase C — a node will not connect | nothing yet. The chain is one node deep and can still be abandoned. |
| **Phase D onwards** | the chain exists. Consensus cannot be changed. A defect here is lived with, not fixed. |

The temptation at 02:00 will be to push through a step that half worked.
The whole reason the irreversible line is drawn at Phase D is so that the
answer before it is always *stop*.

---

## Two decisions to make before the day, not on it

**Does testnet keep running?** It costs a machine and it is where every
future change gets tested before it reaches people's money. Two independent
operators are on it. Stopping it loses them and loses the rehearsal ground.
Keeping it means running two chains. Decide in advance and write the answer
here.

**Who is awake?** Every step above assumes one person doing them in order.
If that person is asleep at 04:00 the chain does not stop, but nobody is
watching it either. Decide what is checked in the morning rather than
watched all night.

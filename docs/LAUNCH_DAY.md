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

Deliberately disabled was not enough. On 29 August I started the mainnet node
myself, on purpose, to test ElectrumX against it — and left a datadir behind
that could never start again. Knowing the rule did not help; nothing stopped
me. So `wamd-mainnet.service` now runs `scripts/genesis_gate.sh` as an
**`ExecCondition`**, which declines the start before 15 September and passes
silently after it. Both hosts have it, and on both the refusal was tested
rather than assumed: one refusal in the journal, unit inactive, no retry.

**Before 15 September, `systemctl start wamd-mainnet` returns success and
leaves the node not running.** That is how `ExecCondition` works — a
condition that is not met is not a failure — and the alternatives were worse:
as an `ExecStartPre` the refusal *is* a failure, and `Restart=always`
restarts a unit whose `ExecStartPre` failed, so every refusal became a loop.
The reason is written into the journal each time. After 15 September the
condition passes and the question stops existing.

A deliberate rehearsal passes `WAM_ALLOW_PRELAUNCH_START=1`, and is told in
the journal to empty the block database afterwards.

### Both hosts are on UTC — settled 2026-08-29

France ran `Europe/Berlin` and Singapore `Etc/UTC`, so at 00:00 UTC on 15
September one journal would have said 02:00 while the other said 00:00.
Nothing the chain does was affected — genesis, `MAX_FUTURE_BLOCK_TIME` and
every block timestamp are absolute — but a person reading two logs side by
side at two in the morning is, and that is exactly when an hour disappears.

It was found by a check of mine reporting a crash loop that was not
happening: it wrote a UTC mark and `journalctl --since` read it as local
time. France is now `Etc/UTC`. The calendar timers were re-checked after the
change rather than assumed — `wam-backup.timer` fired once on the way past,
succeeded, and its next run is 03:20 UTC, because a backup that quietly
stopped being nightly is a failure this project has already had.

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

### Rehearsed 2026-08-29, so it does not have to be discovered on the night

The installer used to write one env file, one database and one service name
for every network. Running it for mainnet would have overwritten the testnet
configuration in place — pointing a mainnet server at a database indexed for
another chain and taking the testnet servers down in the same move.

It is now one instance per network: `wam-electrumx@mainnet` and
`wam-electrumx@testnet`, each with its own `/etc/wam/electrumx-<net>.env`,
its own `/var/lib/electrumx-wam-<net>`, and its own ports.

Three things were found by doing it rather than reading it:

- **The mainnet node had no fixed RPC credentials.** It authenticated by
  cookie, and the cookie is rewritten at every node start, so an ElectrumX
  configured against it would have worked once and failed silently at the
  node's first restart. Both hosts now have a fixed pair, added while their
  mainnet nodes were stopped. The installer refuses a cookie-only node.

- **ElectrumX does not index the genesis block.** The node has all five
  premine outputs in its UTXO set — verified, `gettxoutsetinfo` reports
  2,000,000 WAM at height 0 — but a light wallet asking Electrum about those
  scripts is told zero. Ordinary blocks index correctly; the testnet
  instance returns real balances at 3,468 blocks deep. So anyone checking
  the founder reserve must ask a node, not a wallet, and that is worth
  saying before someone reports it as a missing premine.

- **The ports collide.** Testnet's ElectrumX holds 50001/50002/50004, and
  those are the mainnet numbers published in the Komodo entry and the
  listing sheet. Mainnet cannot take them while testnet is on them.

16. **Electrum: one command per host.**

    The handover was done on 2026-08-29, deliberately not on the night.
    Testnet's ElectrumX now lives on 51001/51002/51004 with its index
    carried across rather than rebuilt, and 50001/50002/50004 have been held
    empty since — so nothing answers on a mainnet port with a testnet chain,
    which is the state a listing reviewer would have found a defect in.

    The mainnet instance is installed on both machines, configured against
    the published ports, and was proved end to end on rehearsal ports:
    plain, TLS and WebSocket-over-TLS all answered and reported the mainnet
    genesis hash. So on the day there is nothing to install and nothing to
    decide:

    ```bash
    systemctl enable --now wam-electrumx@mainnet
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

20. **Point the bot at mainnet first.** This step exists because a dry run
    on 29 August produced the launch announcement headed:

    ```
    🧪 TESTNET — coins here have no value
    ```

    The bot asks whichever node its config names which chain it is on, and
    labels the message accordingly — which is right, and is why nothing it
    sends can be mistaken for the wrong network. But `/etc/wam/announce.json`
    names port 19554, and nothing in this document had ever said to move it.
    The message would have been correct and the banner would have been
    correct, and the two together would have announced the birth of the chain
    over a line saying its coins are worthless.

    So: edit `/etc/wam/announce.json` to the mainnet RPC port (9554) and
    credentials, then restart `wam-announce`.

21. **Announce.** `--expect main` is not optional. It asks the node what
    chain it is on and refuses to send anything if the answer is not the one
    you named — because a note in a document does not stop a mistake at two
    in the morning, and this does.

    ```bash
    node bots/say.js --file posts/launch.txt --expect main --dry-run   # read it
    node bots/say.js --file posts/launch.txt --expect main
    ```

    The text is written and lives at `posts/launch.txt`. Read it once in
    daylight before the night, not for the first time at 02:00.

22. **The release for mainnet** — if a new version is cut for the day, its
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

The expensive half of this was settled on 29 August, before the day, so the
decision no longer costs anything on the night: testnet's ElectrumX already
moved to 51001/51002/51004, and mainnet's ports are already free. Whichever
way the answer goes, launch night is one `systemctl enable --now` per host.

Memory was measured rather than estimated, and both networks fit on both
machines: Singapore has 958 MB free and needs about 605 MB, a margin of
roughly 350 MB with no swap on the machine. It fits, and it is the tightest
thing on that host.

**One thing is still outstanding and is not ours to do.** ufw allows
51001/51002/51004 on both hosts, but Contabo and Hetzner each drop inbound
TCP to any port not on an allow-list in their control panel, and a dropped
packet is silent — so the servers look perfect from the inside while nothing
reaches them. Until those three ports are added in both panels, testnet's
Electrum is reachable only from the machines themselves. Nothing about
mainnet depends on it: 50001/50002/50004 were already open there.

**Who is awake?** Every step above assumes one person doing them in order.
If that person is asleep at 04:00 the chain does not stop, but nobody is
watching it either. Decide what is checked in the morning rather than
watched all night.

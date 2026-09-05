# Rehearsals

One rehearsal a day until launch, decided on 4 September 2026.

The reasoning is not that something is expected to be wrong. It is that every
rehearsal so far has found something no amount of reading found, and the only
honest measure of whether this is ready is **how much a rehearsal still
finds**. A day that finds nothing is the first real evidence of solidity. Four
findings in two hours, which is what Phase E gave on 4 September, is not.

Three rules, or this becomes a ritual:

1. **Rotate the ground.** Rehearsing the same phase twice finds the same thing
   twice. Each day covers something the last did not.
2. **Write down what it found, every time, including nothing.** The rate is
   the measurement. Without a number per day, "it feels solid" is all anyone
   has, and this project has been wrong about that repeatedly.
3. **The heavy rehearsals go first.** One on 14 September that finds a defect
   is a defect that launches with us. Front-load.

---

## The schedule

| Day | Rehearsal | Needs |
|---|---|---|
| 4 Sep | **Phase E** — Electrum, pool and explorer against a real mainnet node | done |
| 5 Sep | **Restore a backup** end to end, onto a clean machine | nothing |
| 6 Sep | **A stranger follows START_HERE** from nothing: download, verify, sync, mine | nothing |
| 7 Sep | **Phases A→D** in full on v0.1.6, from an empty directory | nothing |
| 8 Sep | **Phase F** — the announcer posting to mainnet | nothing |
| 9 Sep | **France dies.** Does Singapore carry the network alone? | nothing |
| 10 Sep | The **third seed**, if the server has arrived | Vultr |
| 11–12 Sep | Repeat whatever found a defect; publish the BitcoinTalk announcement | signed release ✓ |
| 13 Sep | **Freeze.** No change but a critical fix |  |
| 14 Sep | Full sweep, and read LAUNCH_DAY.md line by line |  |
| 15 Sep | Launch |  |

Only 10 September depends on anybody else. Contabo's panel and Vultr's
approval block one line each; the rest proceeds whatever they do.

### Why 5 September is first

`there is something to restore from` checks that a file exists. It has never
checked that the file **opens**. There are nineteen GPG-encrypted archives on
the two servers and not one has ever been decrypted and restored.

An untested backup is not a backup. It is a belief, and the day it is tested
is the day it is needed.

---

## What each rehearsal found

| Date | Rehearsal | Found | Fixed |
|---|---|---|---|
| 27 Aug | Genesis values, v0.1.5 | consensus values verified | — |
| 28 Aug | Phase A/B from an empty directory | a pre-launch mainnet node cannot survive a restart | `genesis_gate.sh` |
| 29 Aug | Phase E, ElectrumX | mainnet node had no fixed RPC credentials; ElectrumX does not index genesis; **ports 50001–50004 collided** | per-network instances, testnet moved to 51xxx |
| 30 Aug | Phase D, the pool wallet | wallets are not under `wallets/` unless it already exists | wallet created and proved to survive the wipe |
| 4 Sep | **Phase E against a real mainnet node** | **six checks asked about mainnet and answered about testnet**; the pool's testnet and mainnet configs claim the same four ports; the gate printed an override that does nothing; `check_explorer` called a height-0 chain a fault | `scripts/wamcli.py`, `move_testnet_pool.sh`, gate message, treasury check |

| 4 Sep | **The announcement, written against the running system** | **`verify_release.sh` told a first-time reader a good release was forged**; the release page ships no key and no checker; `v0.1.6` is a pre-release, so `/releases/latest` skips it | `SELF_DIR` resolved before the `cd`; the drafts link the tag and clone the checker |
| 5 Sep | **Cutting v0.1.7 and installing it** | **the release notes were the commit message, not the tag** — a wrapped `MANDATORY:` in prose made the announcer post UPDATE REQUIRED for a release that changes nothing; the four commands in `RELEASING.md` needed `gh`, which is not on the machine holding the key, and signed `SHA256SUMS` unread; **`install_release.sh` checked the checksums and never the signature**; `check_docs_version.py` audited `site/index.html`, the one page with no download instruction, and skipped the three that have eleven; the release page told readers to run `sha256sum -c` alone | `git cat-file tag`, MANDATORY only as the first line, and the mirror of the consensus check; `sign_release.sh`; the installer now calls `verify_release.sh`; `scripts/lib/docversion.py` |
| 5 Sep | **Restore a backup, end to end** | nothing in the backup; **the node restart lost block 5783** — the pool read "Loading wallet…" as a rejection and threw a valid block away | `jobManager` retries only where no daemon answered |

Five in one evening, in a phase that had been rehearsed once already. That is
the number to watch.

The last one was not found by a rehearsal on the schedule. It was found by
writing the announcement and refusing to publish a command without running it
first — from a clean directory with an empty keyring, which is the only place
the bug exists. Every previous run was from inside the repo, where it cannot
happen.

That is worth a rule of its own: **a check is only tested from where its
audience stands.** `verify_release.sh` exists for somebody who has no reason
to trust us, and it had never once been run by anybody in that position.

### 5 September: the backup was fine, and the rehearsal still found something

The archive decrypts, the pool wallet opens as sqlite, the redis ledger is
valid, all 65 config files are there, every one of the fourteen retained
archives at least opens, and the newest is now on a machine the server cannot
address. That is the first rehearsal on the schedule that found **nothing in
the thing it was rehearsing**.

It found something anyway, in the step taken to reach it. Upgrading the node
to v0.1.7 restarted it while a miner was working, block 5783 was solved inside
that window, and the pool discarded it because `submitblock` came back
`Loading wallet…`. One second later the daemon was fine.

Both halves are worth recording. A day that finds nothing in its own subject
is the evidence of solidity this page was made to measure; and the defect that
did turn up came from *doing an ordinary operation*, not from testing one.
Restarting the node is not rare — it is how every upgrade works, and there is
one ten days before launch, when a discarded block is a miner's reward.

---

## Still open

| | Blocked on |
|---|---|
| TCP 13333–13336 in the Contabo panel, then `scripts/move_testnet_pool.sh` | their panel, which was down on 4 Sep |
| The third server, so `seed3.wamcoin.org` stops being a name with no machine | Vultr's review |

Until the first is done, launch night carries a step that must not be
forgotten: **stop `wam-pool` before starting the mainnet one**, because both
claim 3333–3336.

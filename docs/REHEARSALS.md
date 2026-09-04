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

Four in one evening, in a phase that had been rehearsed once already. That is
the number to watch.

---

## Still open

| | Blocked on |
|---|---|
| TCP 13333–13336 in the Contabo panel, then `scripts/move_testnet_pool.sh` | their panel, which was down on 4 Sep |
| The third server, so `seed3.wamcoin.org` stops being a name with no machine | Vultr's review |

Until the first is done, launch night carries a step that must not be
forgotten: **stop `wam-pool` before starting the mainnet one**, because both
claim 3333–3336.

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
| 9 Sep → 11 Sep | **France dies.** Does Singapore carry the network alone? | nothing |
| 10 Sep → 11 Sep | The **third seed** | done: Contabo US-east, not Vultr |
| 11–12 Sep | Repeat whatever found a defect; publish the BitcoinTalk announcement | done 11 Sep |
| 12 Sep | **Rewrite the 24 marked commit messages** — on a mirror first, verified, then force-pushed | done 11 Sep, a day early |
| 12 Sep | **Windows, end to end** — cross-build, self-test, pool, a block | done 12 Sep |
| 12 Sep | **20× hash rate, arriving and leaving** — does DGW absorb it and recover? | done 12 Sep, by a model checked against 8,838 real blocks |
| 13 Sep | **Freeze.** No change but a critical fix |  |
| 14 Sep | Full sweep, and read LAUNCH_DAY.md line by line |  |
| 15 Sep | Launch |  |

Nothing on this schedule depends on anybody else any more. The third seed
arrived on 11 September and the Contabo panel is answering.

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
| 5 Sep | **A stress test run by someone outside the project** — Sparks60 | **difficulty reached the floor for the first time**: it fell to 0.00024414, the same value as block 1, and stopped. DGW spent its entire 3× range on one drop and we had never seen it reach the bottom. **And our own first account of it was wrong** | the floor and what it costs are written down below; the summary was corrected in the same channel |
| 6 Sep | **A stranger verifies a release, unprompted** — Sparks60 again | **three faults in our own published instructions**, none of them his: it never said to download the release, only to clone and verify; the corrected form still assumed the clone sat beside the downloads, and his was at `/root/wam-coin` while his files were in `/root/Downloads`; and the failure message said "download it from the release page" without saying which of four files | the instruction has no clone in it now — five downloads and one command, wherever the reader is standing; the message prints the commands with the version filled in |
| 6 Sep | **The fixed seeds are exercised for the first time** — Sparks60, cold start with `-dnsseed=0` | **they work.** `Added 2 fixed seeds from reachable networks`, both peers connected one second later, with DNS disabled and no `peers.dat`. Also: our DNS seed answered a stranger's own network from another country, which had never been tested outside our servers | nothing to fix — the feature shipped in v0.1.7 had never once run, here or anywhere |

| 7 Sep | **Phases A→D**, and Phase D's one open item | **the nightly backup could not have covered the mainnet pool wallet, in three ways and two of them silent**: the datadir defaulted to `/root/.wam` whatever the network, so a mainnet run would have encrypted the *testnet* chain and reported success; the archive name carried no network; and rotation counted both networks' archives against one `KEEP=14`, so each would have kept about seven. Also: `START_HERE` promises Windows and macOS builds are "planned" and nothing anywhere is the plan | `wam-backup@.service`/`@.timer`, one instance per network, migrated on both hosts; `ROADMAP.md` §7 |

| 7 Sep | **Build the node for Windows and macOS** — asked for by the founder, against my own judgement that it should wait | **`nMinimumChainWork` stops every new node syncing.** Setting it turns on Core's presync path, which enforces Bitcoin's 2016-block retarget rule, which DarkGravityWave violates at height 1: `invalid difficulty transition at height=1 (presync phase)`. Published releases carry zero, so the live network was never affected — but `check_min_chain_work.py` instructs setting it on mainnet **after launch**. Also: macOS was built against Homebrew's boost, which is newer than Core v28 accepts; three separate files hardcoded `wam-backup.timer` and I fixed two, leaving the panel red in the only one that is looked at; and the consensus gate assumed a free RPC port and a POSIX path, either of which would have failed the Windows runner | `PermittedDifficultyTransition` patched; macOS moved to `depends`; the unit lists discover; the gate picks a free port and converts the path. **Windows then synced 6,029 blocks from genesis and matched all four known blocks** |
| 11 Sep | **A third seed node**, on a clean machine | **five defects, all in paths that run rarely**: `harden_server.sh` called a function it never defines and died one line early, so the git HTTP/1.1 setting never applied; `install_release.sh` resolved its own directory after a `cd` and aborted after downloading the release; it also ran `wamd -version` with `2>/dev/null`, so a missing-library failure exited 127 and printed nothing; **both production servers were carrying a v0.1.5 `wam-wallet` in PATH beside a v0.1.7 node**, because the installer linked three binaries and stopped; and the runtime library line this project publishes **names a package that does not exist on Ubuntu 24.04**, with `libevent-pthreads` missing from both releases' lists | all five fixed; `seed3.wamcoin.org` now answers with a machine, and all three nodes report byte-identical binaries |
| 11 Sep | **France dies** — every WAM service stopped on the France host for eight minutes | **the chain stopped.** Height held at 8,307 across four block times, because the only miner runs on France. The *network* survived — Singapore and the new seed stayed up, agreed, and kept peers — but nothing was added to the chain. Explorer and pool returned 502 for the whole outage; wamcoin.org was unaffected, being on GitHub Pages. One alert did arrive, and **it named the wrong event**: it reported `wam-reorg-watch@testnet.service FAILED`, not that a seed node had died. **Everything that alerted ran on the dying machine**, so a real power cut would have been silent. And the new seed had no alerting at all | alerting wired on the new seed and proved end to end; the miner and the cross-machine watch are decisions, recorded below |

Five in one evening, in a phase that had been rehearsed once already. That is
the number to watch.

### 7 September: the value of building for a platform we were not going to ship

The founder asked for Windows and macOS and I argued for waiting. He was
right, and not for the reason either of us gave.

The argument was about audience: RandomX was chosen so an ordinary desktop
competes, and most ordinary desktops are Windows. That argument stands. But
what the exercise actually bought was a **defect that no amount of reading
would have found**, because it only appears in a binary built from current
main, and every binary this project has ever published predates the change
that causes it.

Four days of rehearsals had not found it. A full sweep does not find it: the
checks all pass, because they run against the deployed v0.1.7 binaries, which
carry `nMinimumChainWork = 0` and never enter the path. It would have been
found on 15 September or shortly after, by newcomers who could not sync and
had no way to say why.

The lesson is not "build for more platforms". It is that **a check running
against yesterday's binary cannot see today's source**, and this project's
sweep is entirely of that kind. That gap is now the most valuable thing on
this page and it does not have an answer yet.

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

## The history rewrite, and why it is a rehearsal rather than a chore

Twenty-four commit messages between 24 August and 5 September carry an
assistant attribution the founder asked to have removed. It is in commit
messages only: no tracked file, no tag message, no release page and no
binary carries one, and check_attribution.py in the sweep makes a new one
impossible.

Removing them rewrites 217 commits -- 138 when this was written, and 121
have been added since. v0.1.0 to v0.1.5 are untouched; v0.1.6 and v0.1.7
move.

What that does NOT break, measured rather than assumed: verify_release.sh
compares a signature to the binaries and never looks at a commit, so every
published download still verifies exactly as before. What it does break is
one informational line on each of two release pages -- "Built by GitHub
Actions from <sha>" -- and every clone anyone has taken, which then needs a
forced fetch.

It is scheduled, and rehearsed on a mirror, because it is irreversible and
because doing it as the tail end of a long night is how an operation that
costs a line of text ends up costing a repository. The order:

1. `git clone --mirror` to a scratch directory. Everything below happens
   there first, and nothing is pushed until it passes.
2. Rewrite the messages. Confirm: 138 new hashes, the same trees --
   `git diff <old-tip> <new-tip>` must be empty, because nothing about the
   content is changing.
3. `check_attribution.py` reports zero, including the backlog.
4. Only then force-push, and immediately edit the two release bodies to name
   the new commits.
5. Say so in the channels, once: anyone with a clone needs
   `git fetch --all --prune` and a reset. A public history that changes
   without a word is how a project looks compromised.

If step 2 or 3 does not come out clean, nothing is pushed and the 24 stay.
They cost the system nothing where they are.

### 6 September: the day's rehearsal was performed by somebody else

The schedule said *a stranger follows START_HERE from nothing: download,
verify, sync, mine*. Nobody here ran it. Sparks60 did, without being asked,
and it failed three times before it worked — every time because of what we
had written, and never because of anything he did.

Then it passed:

<!-- wam:quote-begin -->
    ok    signed by the key published in SECURITY.md
    ok    1 file(s) match the signed list, byte for byte

    this is the WAM release, unmodified since it was signed
<!-- wam:quote-end -->

That is the first time anyone outside this project has verified a WAM release
and been told the truth by the tooling. On 4 September the same script told a
first-time reader that a perfectly good release was forged. This morning the
instructions around it were incomplete in two more ways.

"1 file(s)" is correct and worth explaining rather than leaving to be
noticed: he downloaded the node package and not the miner, and the check
reports what it actually verified instead of implying it checked everything.
A count that could not be less than the number of files listed would be a
count that means nothing.

The rule this keeps proving, in a new place each time: **a check is only
tested from where its audience stands.** We had tested verify_release.sh from
a clean directory with an empty keyring — and with the files already
downloaded and the repository already cloned, because the person testing it
had just built them both.

### 6 September: v0.1.7's headline feature ran for the first time, in somebody else's hands

The release notes said a node can now find the network when DNS cannot be
trusted. That was true of the code and unproven in the world. Every node this
project runs already knows its peers, so the fallback had never been reached
-- not once, on any machine, since it shipped.

Two of his runs did not exercise it either, and the log said so honestly both
times: `Added 0 fixed seeds`, because DNS had already worked and the seeds
were not needed. The third run disabled DNS:

<!-- wam:quote-begin -->
    Command-line arg: dnsseed=0
    Creating peers.dat because the file was not found
    DNS seeding disabled
    Adding fixed seeds as -dnsseed=0 ... and neither -addnode nor -seednode are provided
    Added 2 fixed seeds from reachable networks
    New outbound-full-relay peer connected: version: 70016, blocks=6137, peer=0
<!-- wam:quote-end -->

One second from an empty address book to a connected peer, with the only
route in being the two addresses compiled into the binary.

The other half is worth as much and is easier to overlook: the cold start
before it showed `2 addresses found from DNS seeds` from
`testnet-seed.wamcoin.org` -- on a stranger's machine, on his connection, in
his country. Every previous test of that seed was from our own servers, or
from Google and Cloudflare, which answer for reasons that need not apply to
anybody else.

Neither of those facts could have been established from inside this project,
and both were established in an afternoon by somebody who was told what to
watch for and why.

## Still open

| | Blocked on |
|---|---|
| TCP 13333–13336 in the Contabo panel, then `scripts/move_testnet_pool.sh` | **nothing any more.** The panel was down on 4 September and has been used repeatedly since |
| ~~The third server, so `seed3.wamcoin.org` stops being a name with no machine~~ | done 11 Sep, at Contabo. Vultr took the money and never delivered a server, and refunded it |

Until the first is done, launch night carries a step that must not be
forgotten: **stop `wam-pool` before starting the mainnet one**, because both
claim 3333–3336.

---

## 11 September: France dies

Two days late, and worth the wait only because it was run properly: every WAM
service on the France host stopped at 13:37:24 UTC and started again at
13:45:02. Eight minutes. The machine and its SSH stayed up, so the simulation
is of a **service death, not a power cut** — and the difference turned out to
be the most important thing it found.

### The chain stopped

```
T+2min  h=8307     T+5min  h=8307
T+3min  h=8307     T+6min  h=8307
T+4min  h=8307     T+7min  h=8307
```

Four block times, no block. Singapore and the new seed stayed up, stayed
connected, and agreed with each other throughout — the network was never in
danger. But **the only miner on this chain runs on France**, so nothing was
being added to the thing the network was faithfully agreeing about.

The question in the schedule was "does Singapore carry the network alone?"
The answer is: it carries the network and it does not carry the chain. Those
are different things and the schedule line did not distinguish them.

This is not a defect to fix in software. It is a decision to take before
15 September, and it is the founder's: either a second machine mines, or the
chain is known to stop when one machine does.

### The alert named the wrong event

One message arrived, and it said:

```
ALARM  wam-reorg-watch@testnet.service FAILED on vmi3500463
```

A watcher failed. That is true, and it is the smallest true thing that could
have been said. A seed node had died, the explorer and the pool were
returning 502 to the public, and the chain had stopped — and the alarm
reported a helper script exiting non-zero.

`wamd` itself has `OnFailure=`, but a `systemctl stop` is not a failure, so it
said nothing. What spoke was the collateral: another unit noticed its node was
gone and died of it. The alarm we heard was an accident of dependency.

### Everything that alerted was on the machine that died

The reorg watcher that noticed, the alert unit that fired, and the credentials
it sent with are all on France. This message arrived because France was alive
enough to send it.

**A power cut would have been silent.** Singapore does not watch France. The
new seed watches nothing. The only thing that polls all three is the
operations panel on a laptop that is not always on.

That is the finding with the longest reach, and like the miner it is a
decision rather than a patch: something off-machine has to watch each machine,
or a dead host is discovered by somebody noticing.

### And the new seed could not have spoken at all

It had no `OnFailure=` and no `wam-alert@.service`, because its unit was
written by hand during the install instead of taken from `deploy/systemd/`.
Wired, and then proved rather than assumed: a probe unit was failed
deliberately and the alert path ran to completion from that host.

### The one thing that did notice spoke only when it came back

At 13:50 UTC, five minutes after the services were restarted, this arrived:

```
notice  vmi3500463: now listening on port(s) 19554, 19555, 19556, 3333,
3334, 3335, 3336, 51001, 51002, 51004, 8001, 8080, 8081, which were closed
before.
```

Thirteen ports had gone and come back, and that is the only message in the
whole exercise that was about the ports at all. It reported the **recovery**.

`scripts/login_watch.py` compares what is listening now against what was
listening last time and speaks about the difference in one direction only:

```python
if state.get("ports") and ports - set(state["ports"]):
```

Newly opened ports, never newly closed ones. That is correct for what it is —
a security watch, where a port appearing means somebody may have opened a way
in, and a port disappearing means a service stopped. It is not a defect in
login_watch.

The consequence is still worth writing down: **a closing port is not an event
anywhere in this system.** Thirteen of them went silent on a seed node and the
only machine that could tell was the one they went silent on.

---

## 11 September: the history rewrite, performed

Done a day early, and the mirror earned its place twice before anything was
pushed.

**What was removed:** one line -- a `Co-Authored-By:` trailer naming the
assistant, not written out here for the same reason it was removed -- from 24
commit messages between 24 August and 4 September. Nothing else in any
message changed, which was checked rather than hoped: every subject line
identical and in the same order, and every body equal to the old body minus
that trailer — zero exceptions across 338 commits.

**What moved:** 217 commits, `v0.1.6` and `v0.1.7`. `v0.1.0` through
`v0.1.5` kept their exact hashes, as the plan required.

**What did not move:** any file. `git diff <old tip> <new tip>` was empty.

### The first attempt moved all eight tags, and it was wrong

Run over `--all` with a message filter that normalised trailing whitespace,
it rewrote every commit in the repository — including the five releases that
had no attribution anywhere near them.

Two causes, and only one was mine. The filter called `rstrip()` on every
message, touched or not, which is enough to move a hash. And the root commit
carries a `gpgsig` header — GitHub signs the commit it creates when a
repository is made through the web UI — and `filter-branch` strips signatures
when it recreates a commit, so the very first hash changed and the change
cascaded through all 338.

Measured before deciding anything: **one commit in 338 is signed**, by
GitHub's web-flow key, on "Initial commit". Losing it costs nothing. But the
cascade it caused would have broken a promise in this plan, and the fix was
to rewrite only `4a97de8^..main` and to return untouched messages byte for
byte.

That is what a mirror is for. Both attempts took three minutes each; the
wrong one would have taken the repository.

### Pushing the tags re-ran the release workflow, which the plan did not say

`v0.1.7` re-ran and succeeded. `v0.1.6` re-ran and failed, at the step called
*Publish the release* — it built for thirteen minutes and then refused to
publish over a release that already exists.

Neither replaced an asset. Checked against the API rather than assumed: every
`updated_at` on both releases still reads August or 5 September. And the
published v0.1.7 was downloaded again afterwards, on a clean machine over a
fast link, and `verify_release.sh` said what it has always said:

```
this is the WAM release, unmodified since it was signed
```

Which was the load-bearing promise of the whole exercise: a signature covers
bytes, not commits.

### The check that guards this had to be told

`check_attribution.py` carries a `BASELINE` commit, and that commit was one
of the 217. It kept resolving on the machine that did the rewrite — git holds
unreachable objects for weeks — so the check went on reporting a backlog of
24 that no longer existed, and on a fresh clone it would have failed outright.

The script predicts this, in a line a few rows under the constant: *"If
history was rewritten, update BASELINE in this file."* It was right, and it
is the only reason the stale count was noticed at all.

### And it left an unsigned draft release behind

The `v0.1.7` run that succeeded did what the workflow is written to do:

```
gh release create "$VERSION" ... --draft
```

That `--draft` is deliberate, and `release.yml` argues for it at length — the
runner cannot sign, the key is on a USB stick, and without the draft every
release went public unsigned until a person noticed. It waits for someone to
sign SHA256SUMS by hand and publish.

What nobody had considered is what happens when a tag is pushed for a release
that is **already published and signed**. A second `v0.1.7` appeared in the
list — a draft, carrying binaries built that afternoon and no signature at
all — sitting one click away from replacing a good release with an
uncheckable one.

It was invisible to the check that went looking. Asked for the releases, the
unauthenticated API returned eight and no duplicates, because **it does not
return drafts**. The founder saw it in the web interface; the measurement
could not. Deleted.

The rule that follows, and it matters on 15 September: **pushing or moving a
tag re-runs the release workflow and creates a fresh unsigned draft.** After
any tag push, look at the releases list in the browser — not through the API
— and delete what the run left behind.

### And `git subtree push` stopped working

Publishing the site is `git subtree push --prefix site origin gh-pages`, and
after the rewrite it was rejected:

```
828241d -> gh-pages (non-fast-forward)
hint: a pushed branch tip is behind its remote counterpart
```

Nothing was behind. `subtree push` derives a synthetic history from `site/`,
one commit per commit that touched it, and every one of those commits had a
new hash — so the branch it computed shared no ancestry with the `gh-pages`
that was already there.

The fix is one line and it is not a workaround:

```
git subtree split --prefix site -b gh-pages-new
git push --force origin gh-pages-new:refs/heads/gh-pages
```

`gh-pages` carries generated output and no history anybody builds on, so
forcing it loses nothing. It was checked before pushing rather than after:
the split branch had the site at its root, the signed channel list with
Bluesky in it, and the new pool port on the start page.

Third consequence of the rewrite that the plan did not name, after the
signature cascade and the re-run release workflow. None of the three was
dangerous; all three cost time at the moment of least patience, which is
the argument for writing them down here.

---

## 12 September: Windows, and the antivirus nobody had asked

Not on the schedule. It was put there on the 12th, three days out, because
the founder said the thing the schedule had got wrong: RandomX was chosen so
an ordinary desktop can compete for blocks, most ordinary desktops run
Windows, and somebody who arrives on launch day and finds nothing he can run
does not come back later to check. The roadmap had Windows as the first item
*after* launch. That was the wrong side of the date.

The rehearsal was: build the whole Windows release, run it on a real Windows
machine, and mine with it against the live pool. Not "does it compile".

### What it found before it found anything else

The node had cross-compiled since 7 September and the miner had never been
built for Windows at all. `build_windows.sh` copied five node binaries and
stopped. So the release that was about to be assembled would have given a
Windows user a wallet and a node and no way to mine — the one thing the
platform was wanted for.

The reason it had gone unnoticed is worth naming: every previous check asked
"does this build" and "does this agree with the chain", and both were true.
Nothing asked "is this a release somebody can use".

Of the miner's 2,600 lines, forty were not portable — a TCP socket in
`stratum.h`, one `localtime_r`, and the assumption that an ANSI escape
colours a terminal. They are now in `miner/src/platform.h`, the only file in
the miner that knows what an operating system is.

Two of the six Winsock differences would have failed silently:

* `SO_RCVTIMEO` takes a `DWORD` of milliseconds, not a `struct timeval`. Pass
  a `timeval` and Winsock reads its first four bytes: a one-second timeout
  becomes one millisecond, and the I/O loop spins a thousand times a second
  burning a core that should be hashing.
* A receive timeout reports `WSAETIMEDOUT`, where POSIX reports `EAGAIN`.
  `stratum.h` sets a one-second receive timeout deliberately so the loop
  always returns and `CheckSilence()` gets to run — so on Windows that
  timeout fires every single second of normal operation. Tested the POSIX
  way it is not "nothing to read", it is an error: the miner would tear down
  a healthy connection once a second, forever, and report a read failure each
  time. It would have looked like a broken pool.

### Measured on Windows 11, 03:04–03:09

```
--self-test     SHA-256, byte order, targets, both official RandomX vectors
connected       pool.wamcoin.org:13333, subscribed, authorized
randomx         full memory (2 GiB dataset) built in 5.52 s
1.88 kH/s       8 of 24 cores
shares          10 accepted, 0 rejected
block 8478      solved at 03:05:46
```

and on the pool, on France:

```
01:05:47  *** BLOCK CANDIDATE at height 8478 by twam1qzrjw…win11 ***
01:05:48  *** BLOCK 8478 ACCEPTED *** reward 50.00010138 WAM
01:05:48  block 8478 recorded: 47.02510037 WAM to 7 workers
```

`.win11` was the worker suffix given to the Windows binary; blocks 8479, 8480
and 8481 came from `.rig1`, the Linux miner on the same pool. So the
attribution is from the pool's own log and not inferred from timing.

**Zero rejected shares is the measurement that matters.** One byte-order
mistake in the header, the nonce or the target comparison gives ten rejected
and no error message — a miner that hashes correctly and finds nothing, which
is the most expensive way to be wrong.

### And then Windows deleted it

Fourteen seconds into the first run, before any of the above:

```
Windows Defender  02:53:21
  Trojan:Win32/Bearfoos.A!ml     SeverityID 5 (Severe)
  file:    wam-miner.exe
  process: pid 35700
```

It terminated the process and removed the file. The first run looked, from
the log, like a miner that connected, took a job at height 8474, hashed for
thirty seconds and then stopped for no reason.

This has no clean fix and pretending otherwise would be the failure. A
program that opens a socket and then uses every core is behaviourally
identical to the cryptojacking malware that infects people without asking;
the difference is consent, which no scanner can see. A publisher certificate
is the only thing that removes the warning, and it costs money and a
registered company.

What was in reach was done, in four parts:

1. **`miner/wam-miner.rc`.** The binary carried no company, no product, no
   description and no version — a property shared by almost nothing a person
   installs on purpose. The node binaries have all of it because Core's build
   system adds it; the miner was one `g++` invocation and never had it. With
   the resource, the same binary mined for five minutes untouched and an
   on-demand scan passed. One trial is not a guarantee and this file does not
   claim to be a fix.
2. **Documented, not defeated** — `docs/MINE.md`, both START_HERE pages, and
   the `RELEASE.txt` inside the archive. What the message looks like, why a
   miner triggers it, that the answer is the SHA256 and the signature rather
   than an opinion, that an exclusion should name one file and never the
   machine, and that anyone asking a user to switch their antivirus off
   entirely is not us.
3. **A CI step that asks Defender first.** `windows-latest` has it, so the
   workflow scans every binary before packaging and writes the verdict into
   the run summary. It never fails the build — a false positive must not be
   able to block a release — but it can never again be a surprise.
4. **The node is offered separately.** `wamd.exe` is not a miner and is not
   normally flagged, so a Windows user who does not want to argue with his
   antivirus can still run a node and hold a wallet.

### 197 MB

`platform-build #10` uploaded `out/windows/` raw: five unstripped
executables. `package_release.sh` has stripped the Linux binaries since the
first release — its own comment reads "Debug symbols are most of the size and
none of the use. 339 MB -> ~30 MB" — and nothing in the Windows path ever
did. On the connection that had to download it, measured at about 16 KB/s,
that artifact is three and a half hours. The release could not be assembled
at all, and the first two hours of the night went on looking for a file that
had never been downloaded.

`build_windows.sh` now strips **before** the consensus gate rather than
after. That ordering is the point: the gate unpacks the archive and syncs the
chain from genesis with the exact bytes a stranger will download, so
`RELEASE.txt`'s claim that these binaries were tested stays literally true.
Strip afterwards and the tested file and the shipped file are different
files.

### The release would not publish, and the thing that stopped it was right

`release.yml` refused v0.1.8. Everything up to the last step passed -- node,
RandomX and miner built, packaged, and the artifact verified against its own
checksums -- and then:

```
   ok       Verify the artifact before anyone can download it
   FAILURE  Publish the release
```

`consensus_floor.py` had reported that v0.1.8 changes a consensus value while
the tag carried no `MANDATORY:` line, and the workflow stops for that on
purpose. The reason it stops is written in its own comments: v0.1.5 moved the
mainnet treasury address, shipped with no warning, and two independent
operators stayed on v0.1.4 for two days.

The change was real. v0.1.7 shipped `nMinimumChainWork` as `uint256{}` on all
three networks; testnet now carries a value, set on 7 September so a fresh
node cannot be walked onto a cheap fabricated history by the first peer it
meets. Mainnet is still zero, so launch was never affected.

**Both ways out were wrong, which is what made this worth writing down.**
Write a `MANDATORY:` line and every channel is told UPDATE REQUIRED for a
release nobody needs to install -- spending, three days before launch, the one
warning that has to be believed on the night. Or do not publish, and ship no
Windows release at all.

The answer was in the gate's own definition, one line above the patterns it
matches: *a node disagreeing about any of these is a node on a different
chain.* Exactly one field reached through `consensus.` fails that test. Two
nodes with different `nMinimumChainWork` accept identical blocks; the value
decides whether a node will begin to trust a header chain at all, which is
liveness and anti-DoS, and `check_min_chain_work.py` already exists for it. A
v0.1.7 node has zero there and follows this chain exactly as before.

So the field is excluded by name, after matching rather than by narrowing the
pattern -- `consensus.\w+` still catches every field by default and an
exception has to be argued for, because a new consensus value must never be
missed because a regular expression was tightened to exclude a different one.
The floor moved to **v0.1.5**, which is what this project's own history
records as the only consensus change since genesis.

A guard that fires correctly and is classified wrongly looks exactly like a
guard that is broken. The difference is whether you read it or silence it.

### And the box said v0.1.8 while the binaries said v0.1.7

Found by running the finished artifact rather than by reading anything.
`platform-build #11` produced `wam-coin-v0.1.8-x86_64-w64-mingw32.zip`, and
the node inside it answered

```
WAM Coin version v0.1.7
```

because `--version` on that workflow is a string typed into a form and nothing
compared it to anything. The archive was right in every other respect: PE32+,
stripped, consensus-gated from genesis, miner self-tested on Windows. And the
command a person runs to answer "am I on the version that moved a consensus
rule?" would have told him the wrong thing.

`sign_release.sh` catches this from the other end -- it refuses to sign a list
of v0.1.8 names from a v0.1.7 checkout -- and that guard would have held. But
it holds at the last possible moment, on the machine with the offline key, at
the end of a long night. `package_platform.sh` now asks before it packages
anything: first `patch_upstream.py`, which is the authority the build stamps
into the binaries, then the binaries themselves, by reading the version string
out of the file rather than running it -- a PE cannot be executed on the Linux
runner that cross-compiled it, and the same rule has to hold for both
platforms.

---

## 12 September: 20× hash rate, arriving and leaving

`docs/ROADMAP.md` section 2.7 has said since the roadmap was written:

```
2.7 | Point 20× hashrate at it for an hour, then remove it
    | proves DGWv3 absorbs and recovers
```

It was never run. It was found by the founder asking, three days out, which
attacks a chain with no value actually attracts — and the honest answer puts
this first, because **nobody has to mean us harm for it to happen.** The
network is about one ordinary desktop's worth of hash rate, RandomX rents by
the hour, and somebody hunting a cheap coin points real hardware at it,
difficulty climbs, and then they leave. The difficulty they caused stays
behind.

### It cannot be bought, so it was computed — and the model was checked first

We cannot rent twenty times our own network to find out. `scripts/dgw_model.py`
mirrors `DarkGravityWave()` from `src/wam/pow.cpp` exactly: the 24-block
window, the `(avg·n + t)/(n+1)` running mean walked backwards from the newest
block, the `[target/3, target·3]` clamp, integer division throughout, and the
compact encoding's own truncation.

A Python reimplementation of a consensus rule is precisely the shape of thing
this project distrusts — one fact in two places has bitten it three times. So
the model is refused unless it can reproduce the past:

```
does the model reproduce the chain that already exists?
  ok    8838 blocks, every one predicted exactly
        heights 24 to 8861
```

Every block from height 24 to the tip, its nBits computed from its own 24
predecessors and compared with what the chain actually carries. Eight thousand
independent comparisons against a chain the C++ produced. One mismatch and the
file says so and stops.

### What it says

| the visitor | difficulty rises | slowest block after they go | back to 2-minute blocks |
|---|---|---|---|
| 20× for 1 hour | 11.6× | 23 min | ~2 hours |
| 50× for 1 hour | 11.9× | 24 min | ~2 hours |
| 100× for 1 hour | 12.1× | 24 min | ~2 hours |
| 20× for 6 hours | 21.1× | 42 min | ~3 hours |
| **100× for 6 hours** | **105.7×** | **3 h 29 min** | **~14 hours** |

**Duration matters far more than magnitude, and that was not obvious.** A
hundredfold burst for one hour is nearly harmless: only about thirty blocks
can enter the 24-block window in that time, and the 3× clamp bounds how far
one retarget can move, so difficulty gets nowhere near a hundredfold. Somebody
who *stays* for six hours lets it climb the whole way, and their departure
leaves a chain that needs most of a day to recover.

So the thing to fear is not a spike. It is a guest.

The ratios are what carry over to mainnet. The model starts from the chain's
own tail, so the absolute hash rate is today's, but every number in that table
is a multiple and a multiple does not care what the base is.

### What is NOT being done about it

**No consensus change.** Shortening the window would respond faster and
oscillate more; an emergency-difficulty rule of the kind some chains carry is
a consensus rule invented in a hurry two days before launch. Both are worse
than the thing they fix. DGW's behaviour here is a known property of DGW, it
is survivable, and every small chain lives with it.

What is in our hands is arithmetic and a written response, and both are now.

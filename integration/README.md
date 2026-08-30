# Integration files, prepared in advance

Everything a venue needs from us, written out before it is asked for, so that
answering a listing enquiry is copying a file rather than starting work.

Each subdirectory holds what that venue actually consumes. Five of the six take
a pull request rather than a web form; the sixth, Maya, is not a listing at all
but a chain client inside their node.

| Venue | What it consumes | Ready |
|---|---|---|
| [Komodo Wallet](komodo/) | PR to `GLEECBTC/coins`: coin entry, electrum servers, explorer, icon | [#21](https://github.com/KomodoPlatform/coins/pull/21) went to a dead mirror — the live registry is `GLEECBTC/coins`, see [SUBMIT.md](komodo/SUBMIT.md) |
| [Block DX](blockdx/) | PR to `blocknetdx/blockchain-configuration-files`: 2 confs + manifest | **open, and being worked on** [#197](https://github.com/blocknetdx/blockchain-configuration-files/pull/197) |
| [Haveno](haveno/) | PR to `haveno-dex/haveno`: asset class, test, service entry | closed [#2528](https://github.com/haveno-dex/haveno/pull/2528) — needs a market price first |
| [BasicSwap DEX](basicswap/) | PR to `basicswap/basicswap`: a Python interface package | closed [#701](https://github.com/basicswap/basicswap/pull/701) — *"mainnet is scheduled for 2026-09-15"*, resubmit after |
| [Bisq](bisq/) | PR to `bisq-network/bisq`: asset class, test, service entry | closed [#8030](https://github.com/bisq-network/bisq/pull/8030) — they add no new altcoins |
| [Maya Protocol](maya/) | a node chain client in Go, not a listing | months, and theirs to want |

And one that is not a venue at all but blocks three of them:

| Registry | What it consumes | Ready |
|---|---|---|
| [SLIP-0044 and SLIP-0173](slips/) | one table row each, to `satoshilabs/slips` | **merged 2026-08-26** [#2051](https://github.com/satoshilabs/slips/pull/2051) — coin type 5718349, prefixes `wam` / `twam` / `wamrt` |

## Where this actually stands, 2026-08-30

Enquiries were sent 2026-08-18 and all six venues replied within hours, every
one of them pointing at a GitHub repository: listings are made by pull
request, not by application.

Since then, six submissions and one merge. Every refusal has been about
policy or timing; **not one has been about the code**:

- **SatoshiLabs merged ours.** They are the only party that examined the
  parameters themselves, and coin type 5718349 with prefixes `wam` / `twam`
  / `wamrt` is now in the registry every hardware wallet derives from.
- **Bisq** add no new altcoins at all. Nothing to do with WAM.
- **Haveno** answered *"we only consider coins with market traction /
  price"* — a sequencing rule. They are where a coin arrives, not where it
  starts.
- **BasicSwap** closed with *"mainnet is scheduled for 2026-09-15"*.
  Resubmit after that date.
- **Block DX** is open and a maintainer is preparing a batch that includes
  it, and intends to test the wallet in docker.
- **Komodo** — sent 2026-08-29 to `KomodoPlatform/coins`, which is what
  Komodo's own documentation names and which turns out to be a dead mirror:
  last commit 2025-12-05, pull requests open since February, and its final
  commit was a merge *from* GLEECBTC. The live registry is
  `GLEECBTC/coins` — a bot updates it daily and #1974 merged this morning.
  See [komodo/SUBMIT.md](komodo/SUBMIT.md).

Two mistakes worth writing down rather than learning twice.

**The order was wrong.** Komodo is the venue a coin starts at and it was
submitted last, while three venues that gate on a market price were
approached first. A wallet asks whether the entry is correct; an exchange
asks whether anyone is trading it. Only one of those can be answered before
launch.

**And twice now a submission has gone to a fork nobody reads.** BasicSwap
went to `tecnovert/basicswap#2`; Komodo went to `KomodoPlatform/coins#21`.
Both were caught by the founder, and both times from the same evidence: a
pull request number far lower than an active repository would hand out. #2
and #21, against #701, #2528, #8030 and #2051 everywhere else. Before
submitting anywhere, check the repository's last commit date and its newest
pull request number — a registry of 782 coins whose newest PR is #21 is not
being read by anyone.

---

## The Electrum server, which was the one thing missing

Komodo Wallet requires **ElectrumX servers with valid SSL** for a UTXO coin —
it is a directory in their repository, not an optional field.

**Two run**, at `electrum.wamcoin.org` and `electrum2.wamcoin.org`, on
deliberately different providers — two servers at one provider are one
outage. Both were verified from a machine other than themselves: valid
certificate, protocol answers, and a genesis hash matching what the node
reports. `integration/electrumx/` builds one from nothing.

Since 2026-08-29 there is one instance per network — `wam-electrumx@testnet`
and `wam-electrumx@mainnet`, each with its own env file, database and ports.
Before that a single instance served whichever network it was installed for,
and running the installer for mainnet on launch night would have overwritten
the testnet configuration in place.

Testnet now answers on **51001/51002/51004**. The mainnet numbers —
50001/50002/50004, which are what `komodo/electrums-WAM.json` publishes — are
held empty until 15 September, and the mainnet instances are installed on
both hosts and deliberately not started. A testnet server answering on a
mainnet port is worse than silence: a reviewer who connects, gets a working
server, and reads back a genesis hash that is not the one in the entry has
found a defect in the submission.

None of this ever blocked the other two: BasicSwap and Block DX run the daemon
directly and never speak the Electrum protocol.

Light wallets reading a balance without downloading the chain is worth having
whether or not any venue asks for it.

---

## The gap that closed, and the one that stayed

**SLIP-44 coin type — granted.** This section used to say WAM had none and
that `komodo/coin-entry.json` could not carry a `derivation_path` until a
number was assigned. SatoshiLabs merged
[#2051](https://github.com/satoshilabs/slips/pull/2051) on 2026-08-26: coin
type **5718349** (`0x57414D`, "WAM" in ASCII), and SLIP-0173 prefixes `wam`,
`twam`, `wamrt`. The entry carries `m/44'/5718349'` and
`scripts/check_listing_entry.py` compares it against the constant in
`src/wam/wam-params.h` on every sweep.

It is worth being precise about what that is and is not. It is the number
every wallet derives addresses from, and no hardware wallet can support a
coin without one. It is **not** Trezor firmware support: that is a separate
registry, `trezor-firmware/common/defs/bitcoin/`, and WAM is not in it.

**Message signing prefix.** Fixed here rather than left: WAM used Bitcoin's
`"Bitcoin Signed Message:\n"`, which meant a signature proving control of a WAM
address doubled as proof of control of the corresponding Bitcoin address. It is
now `"WAM Coin Signed Message:\n"` — see `WAM-021` in
`scripts/patch_upstream.py`. Changed before launch because afterwards it would
invalidate every signature already produced.

---

## Keeping these honest

The parameters here are duplicated from `src/wam/wam-params.h` and
`src/wam/chainparams.cpp`. `scripts/audit_repo.sh` checks that the values in
this directory still match the source, for the same reason the vesting schedule
is checked in three files: a listing config that disagrees with the chain is an
integration that fails on the first connection, and the venue does not come
back to ask why.

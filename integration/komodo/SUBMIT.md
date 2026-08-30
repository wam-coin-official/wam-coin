# Submitting WAM to the Komodo coins registry

## Which repository — this took two attempts

**`GLEECBTC/coins`.** Komodo's own documentation points at
`KomodoPlatform/coins`, and [#21](https://github.com/KomodoPlatform/coins/pull/21)
was sent there on 2026-08-29. That repository is a dead mirror:

| | KomodoPlatform/coins | GLEECBTC/coins |
|---|---|---|
| last commit | 2025-12-05 | daily, by a bot |
| newest PR | #21 (ours) | #1974 |
| stars / watchers | 0 / 1 | 27 / 7 |
| open PRs | since February, unmerged | merged within days |

Its last commit was *"Merge pull request #1627 from GLEECBTC"* — it was a
downstream mirror and the sync stopped nine months ago.

Blockzero settles it. The same author submitted to both:
GLEEC [#1934](https://github.com/GLEECBTC/coins/pull/1934) on 15 August,
merged in two days; KomodoPlatform #19 on 13 August, still open seventeen
days later. `cipig` and `shamardy` — Komodo's own people — work in GLEEC.

**The pull request number was the tell**, and the founder saw it before I
did: #21 against a registry of 782 coins is not a number an active
repository hands out. It is the same mistake as BasicSwap, where
`tecnovert/basicswap#2` was a personal fork nobody read.

`make_submission.sh` builds against GLEECBTC by default. Set
`WAM_COINS_REPO` to override.

---


Everything below was checked against `KomodoPlatform/coins` at master on
2026-08-29: the four paths exist, the icon size matches theirs, and no `WAM`
is present in any of them.

This is the first venue in the order that matters, and the reason is worth
stating once. Bisq does not add altcoins at all. Haveno answered *"we only
consider coins with market traction / price"*, which is a sequencing rule
rather than a judgement — they are where a coin arrives, not where it
starts. BasicSwap said *"mainnet is scheduled for 2026-09-15"* and closed,
which is the same answer in a different accent.

Komodo is the other kind of venue. Their registry carries more than seven
hundred coins, most of them far smaller than anything with a market, and
what they check is whether the entry is correct — not whether anyone is
trading it yet. A coin gets a price by being somewhere first, and this is
that somewhere.

---

## The four files

| Goes to | From here | What it is |
|---|---|---|
| `coins` | `coin-entry.json` | one object appended to the array |
| `electrums/WAM` | `electrums-WAM.json` | the two Electrum servers |
| `explorers/WAM` | `explorers-WAM.json` | the block explorer |
| `icons/wam.png` | `../../brand/png/wam-platform-128.png` | 128×128, lower case, as theirs are |

`coins` is one large JSON array. The entry is appended to it — the file is
not replaced.

## Every field was checked against the source it describes

Run before submitting, and again if anything in `src/wam` moves:

```bash
python3 scripts/check_listing_entry.py
```

At the last run: eleven fields, zero mismatches, no field missing that
comparable entries carry. `pubtype` 73, `p2shtype` 135, `wiftype` 190 and
`bech32_hrp` `wam` come from `chainparams.cpp`; `avg_blocktime` 120 from
`wam-params.h`; `derivation_path` `m/44'/5718349'` from the coin type
SatoshiLabs assigned.

A listing entry is read by software, not by a person. A wrong `pubtype` does
not look wrong — it sends somebody's coins nowhere.

## The one thing that must be said in the pull request

**The Electrum endpoints do not answer yet, and will not until 15
September.** `electrum.wamcoin.org:50002` and `:50004` are held empty on
purpose: until 29 August a *testnet* ElectrumX was answering there, which is
worse than silence — a reviewer who connects, gets a working server, and
reads back a genesis hash that is not the one in this entry has found a
defect in the submission. Testnet moved to 51001/51002/51004 and the mainnet
instance is installed on both machines, configured, and deliberately not
started.

Saying it in the pull request costs nothing. Having it found costs the
submission.

---

## The pull request

**Title**

```
Add WAM Coin (WAM)
```

**Body**

```
WAM Coin is a standalone layer 1 — a Bitcoin Core v28.1 fork with RandomX
proof of work — not a token on another chain. Mainnet opens 2026-09-15.

Registered with SatoshiLabs, merged into satoshilabs/slips master on
26 August:

  SLIP-0044  coin type 5718349
  SLIP-0173  bech32 prefixes wam / twam / wamrt

  https://github.com/satoshilabs/slips/blob/master/slip-0044.md
  https://github.com/satoshilabs/slips/blob/master/slip-0173.md

Note: there is an unrelated WAM on CoinGecko — a BEP-20 gaming token on BNB
Chain. BEP-20 tokens sit under BNB's coin type rather than holding one of
their own, so there is no collision in SLIP-0044, which lists WAM against
WAM Coin.

Files added:

  coins           the WAM entry
  electrums/WAM   two servers, deliberately on different providers
                  (Contabo and Hetzner) — two servers at one provider are
                  one outage
  explorers/WAM   https://explorer.wamcoin.org/
  icons/wam.png   128x128

Every field in the entry is derived from source rather than transcribed:
pubtype 73, p2shtype 135, wiftype 190 and bech32_hrp wam from
src/wam/chainparams.cpp; avg_blocktime 120 from src/wam/wam-params.h;
derivation_path m/44'/5718349' from the registered coin type.

required_confirmations is 20 rather than the 3 most entries use. WAM is a
new RandomX chain, and the cost of reversing a confirmation is set by
hashrate, not by block timing — so a young chain deserves a larger number
and we would rather ask for it than have a user find out why.

One thing to flag before you test it: the Electrum endpoints do not answer
until 15 September. 50002 and 50004 are held empty until mainnet opens.
Until 29 August a testnet server was answering on them, which would have
reported a genesis hash that does not match this entry, so it was moved to
51001/51002/51004 instead. The mainnet instances are installed on both hosts
and start on launch day.

Consensus rule worth knowing about, since it affects a block's outputs: 5%
of every block subsidy goes to a treasury address, enforced by every node,
until block 400,000. A block that omits it is rejected. Miners receive 47.5
WAM per block until that height and 50 after it.

Source, and everything above is checkable in it:
https://github.com/wam-coin-official/wam-coin

Happy to supply a node, a testnet endpoint, or anything else that helps the
review.
```

---

## After it is open

Record the pull request number in `NOTES.md`, the way #2051 is recorded for
the SLIP registration. A submission nobody wrote down is a submission
somebody re-sends.

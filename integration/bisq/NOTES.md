# Bisq — what a submission needs

Bisq replied to the enquiry sent 2026-08-18 and pointed at their repository, so
this is a pull request to [`bisq-network/bisq`](https://github.com/bisq-network/bisq),
not a form.

## The three files

Read out of their repository on 2026-08-20 rather than from memory: the shape
below is `Litecoin.java`, the closest listed coin to WAM — a Bitcoin fork with
segwit and its own base58 prefixes.

| Copy from here | To there |
|---|---|
| [`WAMCoin.java`](WAMCoin.java) | `assets/src/main/java/bisq/asset/coins/WAMCoin.java` |
| [`WAMCoinTest.java`](WAMCoinTest.java) | `assets/src/test/java/bisq/asset/coins/WAMCoinTest.java` |
| the line below | appended in alphabetical order to `assets/src/main/resources/META-INF/services/bisq.asset.Asset` |

```
bisq.asset.coins.WAMCoin
```

Their service file lists 126 assets and is sorted; `WAMCoin` goes between
`Vertcoin` and `Webchain` in the coins block.

## The three constants, and where they come from

`NetworkParametersAdapter` needs exactly these. Each is duplicated from
`src/wam/chainparams.cpp`; if they disagree, the source wins and this file is
wrong.

| Field | Value | Source |
|---|---|---|
| `addressHeader` | 73 | `base58Prefixes[PUBKEY_ADDRESS]` — addresses start `W` |
| `p2shHeader` | 135 | `base58Prefixes[SCRIPT_ADDRESS]` — start `w` |
| `segwitAddressHrp` | `wam` | `bech32_hrp` |

Nothing else is required. Bisq does not run a node for the asset and does not
need the RPC port, the emission schedule or the genesis hash: it validates an
address and settles the trade off-chain, so the whole integration is these
three numbers plus a name.

## The addresses in the test are real

Every valid address was produced by `getnewaddress` on a WAM mainnet node, and
every invalid one was handed to `validateaddress` and refused. None was written
by hand. The four cases that matter are there for a reason:

- a Bitcoin address — the version byte is not ours
- a `bc1` address — the hrp is not ours
- a `twam1` address — WAM testnet must never validate as mainnet
- a valid address with its last character changed — the checksum must catch it

A test full of invented addresses fails on the reviewer's first build, which is
a worse first impression than not submitting.

## What is not settled, and must be asked rather than assumed

Bisq's asset listing has been through several policy changes: proposals in
their repository describe a DAO vote plus a non-refundable application fee paid
in BSQ by proof of burn, and a trade-volume threshold below which an asset is
delisted again. Those proposals are years old and their current force is not
something to guess at from the outside.

**Ask them directly, in the reply, before opening the pull request:**

1. Is a DAO proposal and vote still required, and what is the application fee
   in BSQ today?
2. Is there still a trade-volume threshold, and what happens to an asset that
   does not reach it?
3. Do they require a named maintainer who commits to answering issues about the
   asset, and what does that commit to?

The code above costs nothing to prepare and is correct whatever the answers
are. The fee and the maintainer commitment are decisions with a price, and they
belong to the founder, not to a guess made here.

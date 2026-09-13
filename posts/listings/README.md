# The five venues, and when each is answered

Five integrations were opened before mainnet existed. **Not one of them was
closed on the code.** The objections were a date, a price, a name collision
and a maintainer's batch — which is worth writing down once, because it is
the actual state of the work rather than an encouraging way of putting it.

| venue | who said what | send |
|---|---|---|
| **BasicSwap** [#701](https://github.com/basicswap/basicswap/pull/701) | `nahuhh`: *closed: "Mainnet is scheduled for 2026-09-15"* | **14 Sep**, then the live numbers on the 15th |
| **Komodo** [#1975](https://github.com/GLEECBTC/coins/pull/1975) | `cipig`: *"What about the 2 electrums? Do we need to wait till 15.09.?"* — we answered yes | **14 Sep**, then the Electrum proof on the 15th |
| **Block DX** [#197](https://github.com/blocknetdx/blockchain-configuration-files/pull/197) | `tryiou`: *"i'll include your actual PR in this batch… i'll bump you here when ready for testing, ETA few days/weeks"* | **14 Sep**, short. He is doing the work; he does not need chasing |
| **Bisq** [#8030](https://github.com/bisq-network/bisq/pull/8030) | closed on a name collision with the WAM gaming token; the replay-protection answer is in the thread with a 👍 | **14 Sep**, asking reopen or resubmit |
| **Haveno** [#2528](https://github.com/haveno-dex/haveno/pull/2528) | `woodser`: *"We only consider coins with market traction / price."* | **not sent.** Neither exists on day one and inventing them is the one thing that ends a listing conversation permanently |

## Why the 14th and not the 15th

Their queues take weeks — two to three, measured on our own first
submission. A reviewer who opens the thread on the 25th does not care
whether it arrived on the 14th or the 15th, but arriving on the 14th puts
it in the same batch rather than behind it. The day costs nothing.

**What it costs is precision.** Nothing sent on the 14th may say the chain
is live, because it is not. Each draft is therefore in two parts: part 1
states the opening timestamp and everything verifiable today, part 2 is the
proof and carries `<<HEIGHT>>`, `<<BESTHASH>>`, `<<UTC>>` placeholders that
can only be filled from the running chain.

A reviewer who arrives later finds both: a promise with a timestamp, and
the same timestamp kept. That says more about a project than any paragraph
of description.

## Before part 2 is sent

```bash
# the chain exists and all three seeds agree on it
bash scripts/check_nodes_agree.sh --network mainnet <host1> <host2> <host3>

# the Electrum endpoints named in the Komodo entry answer, on mainnet
python3 scripts/check_electrum.py --node <host1> --network mainnet \
    electrum.wamcoin.org electrum2.wamcoin.org
```

Every number a reviewer asks for is in `docs/LISTING_PACKAGE.md`, kept
current rather than retyped into each thread.

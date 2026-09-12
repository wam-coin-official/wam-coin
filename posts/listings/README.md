# The five venues, and when each is answered

Five integrations were opened before mainnet existed. Three were closed on
timing rather than on the code, one is open and waiting on binaries, and one
was closed on a mistaken identity. Each is a person who was told we would come
back — and the day that promise comes due is 15 September 2026.

**Timing is the whole decision here.** A reviewer who tests a claim and finds
nothing answering closes the thread a second time, and a second closure is far
harder to reopen than the first. So nothing that says *"it is live"* is sent
before the thing it names actually answers.

| venue | thread | send | why then |
|---|---|---|---|
| **Block DX** | [#197](https://github.com/blocknetdx/blockchain-configuration-files/pull/197) | **now** | open, and waiting on a maintainer's docker wallet test. Nothing in it claims a live chain — it claims binaries, and those exist |
| **Bisq** | [#8030](https://github.com/bisq-network/bisq/pull/8030) | **now** | closed on mistaken identity. A correction does not need a chain, it needs the genesis hash and the repository |
| **BasicSwap** | [#701](https://github.com/basicswap/basicswap/pull/701) | **after the chain is verified** | they closed it with *"mainnet is scheduled for 2026-09-15"*. Answering before that date is answering their objection with nothing |
| **Komodo** | [#1975](https://github.com/GLEECBTC/coins/pull/1975) | **after Electrum answers on mainnet** | the entry names `electrum.wamcoin.org:50002`. A reviewer who connects before it serves mainnet is right to call it broken |
| **Haveno** | [#2528](https://github.com/haveno-dex/haveno/pull/2528) | **not yet** | closed on *"coins with market traction / price"*. Neither exists on day one, and pretending otherwise is the one thing that ends a listing conversation permanently |

## What must be true before the launch-night two are sent

Measured, not assumed — these are the reviewer's first three clicks:

```bash
# the chain exists and all three seeds agree on it
bash scripts/check_nodes_agree.sh --network mainnet <host1> <host2> <host3>

# the Electrum endpoints in the Komodo entry answer, on mainnet
python3 scripts/check_electrum.py --node <host1> --network mainnet \
    electrum.wamcoin.org electrum2.wamcoin.org

# the download on the release page is this network
bash scripts/check_release_matches.sh
```

Every number a reviewer asks for is in `docs/LISTING_PACKAGE.md`, which is
kept current rather than retyped into each thread.

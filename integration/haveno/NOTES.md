# Haveno — what a submission needs

Haveno replied to the enquiry sent 2026-08-18 and pointed at their repository.
It is a pull request to [`haveno-dex/haveno`](https://github.com/haveno-dex/haveno).

Haveno is a fork of Bisq, so the asset code is the same shape with a different
package name. The files here are the Bisq ones with `bisq.asset` changed to
`haveno.asset`; the three constants and every test address are identical,
because they describe WAM rather than either exchange.

## The three files

| Copy from here | To there |
|---|---|
| [`WAMCoin.java`](WAMCoin.java) | `assets/src/main/java/haveno/asset/coins/WAMCoin.java` |
| [`WAMCoinTest.java`](WAMCoinTest.java) | `assets/src/test/java/haveno/asset/coins/WAMCoinTest.java` |
| the line below | `assets/src/main/resources/META-INF/services/haveno.asset.Asset` |

```
haveno.asset.coins.WAMCoin
```

Their file states its own rule at the top: *"Contents are sorted according to
the output of `sort --ignore-case --dictionary-order`."* By that rule `WAMCoin`
goes between `Tron` and `Zcash`.

## What their list actually looks like

Read on 2026-08-20, and worth reading before spending hope on this:

> Bitcoin, BitcoinCash, Cardano, Dogecoin, Ether, Litecoin, Monero, Ripple,
> Solana, Tron, Zcash — plus four ERC-20/TRC-20 stablecoins.

Eleven coins. Every one of them is among the largest in existence. The most
recent additions were Zcash in March 2026 and Dogecoin, Tron and Solana in
August 2025, so they do still add assets — a few a year, all major.

**A realistic expectation: they will say no, or say nothing.** That is not a
reason to skip it. The files cost an afternoon that was already spent writing
them for Bisq, the answer is theirs to give, and a submission that is correct
and honest costs nothing if refused. It is a reason not to plan around a yes.

Haveno is Monero-centric by design and settles trades off-chain, so it needs no
node, no RPC and no knowledge of WAM's emission — an address validator and a
name, exactly as Bisq does.

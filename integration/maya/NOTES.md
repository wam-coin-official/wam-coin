# Maya Protocol — what this would actually take

Maya replied to the enquiry sent 2026-08-18 and pointed at a GitHub repository,
as all six venues did. Their answer describes where their work happens; it is
not a listing process, and this file exists so that the difference is written
down rather than discovered later.

## Maya is not a listing. It is a chain integration.

The other five venues validate an address and settle a trade. Maya runs nodes
that hold funds on every chain it supports, so adding WAM means their nodes
learn to speak to WAM — watch for deposits, sign and broadcast withdrawals,
follow reorgs, and agree with each other about all of it.

`Maya-Protocol/mayanode` is a mirror of `gitlab.com/mayachain/mayanode`, so the
work happens on GitLab. Its chain clients live in `bifrost/pkg/chainclients`
and, read on 2026-08-20, are:

> binance, bitcoin, cardano, dash, ethereum, evm, kuji, radix, thorchain,
> zcash — over a shared `utxo` package

## The one piece of good news

Bitcoin, Dash and Zcash share that `utxo` package. WAM is a Bitcoin Core v28.1
fork with Bitcoin's RPC interface, transaction format and address handling, so
a WAM client would be a thin configuration of code that already exists rather
than a new one. Technically this is the easiest kind of chain for them to add.

## And the part that is not about code

A chain client is Go that has to be written, reviewed, merged, released, and
then actually run by node operators who each choose to upgrade. After that the
chain needs a liquidity pool with real capital on both sides before a single
swap can happen.

None of that is a pull request, and none of it is on a schedule anyone here
controls. It is months, and it needs their governance to want it.

**So: not a launch-day item, and not something to describe as pending.** The
honest sentence, if anyone asks, is that Maya's integration path is a node
client rather than a listing, and no work has been proposed to them.

`CIP-0001` and its siblings in `Maya-Protocol/CIPs` are not the route: that
repository is a fork of Cardano's improvement proposals and its description
still says so.

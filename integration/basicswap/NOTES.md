# BasicSwap — what a submission needs

BasicSwap replied to the enquiry sent 2026-08-18 and pointed at a GitHub
repository: [`tecnovert/basicswap`](https://github.com/tecnovert/basicswap).

An earlier version of this directory held a single `wam.json`. That was wrong
in form. BasicSwap does not read JSON coin definitions — every coin is a Python
package under `basicswap/interface/`, and a pull request shaped like the guess
would not have applied to anything.

## What it actually takes

Read out of their repository on 2026-08-20.

| From here | To there |
|---|---|
| [`chainparams.py`](chainparams.py) | `basicswap/interface/wam/chainparams.py` |
| [`wam.py`](wam.py) | `basicswap/interface/wam/wam.py` |
| an empty file | `basicswap/interface/wam/__init__.py` |

Plus two lines in `basicswap/chainparams.py`, beside the twelve already there:

```python
from basicswap.interface.wam.chainparams import params as wam_params
...
    Coins.WAM: wam_params,
```

and a member in the `Coins` enum in the same file.

## Why the interface class is nearly empty

`LTCInterface` is 14 KB, and almost all of it is MimbleWimble. `DASHInterface`
is large because Dash has its own address handling. WAM has neither: it is a
Bitcoin Core v28.1 fork whose RPC surface, transaction format, script language,
SegWit and PSBT are Bitcoin's, so `BTCInterface` is already correct for every
method. `WAMInterface` declares its coin type and inherits the rest.

RandomX does not enter into it. It changes how a header is proved, not how a
transaction is built or spent, and no part of an atomic swap reads proof of
work.

## The one thing that blocks this, and it is not ours to fix quickly

Their params dict has a **`bip44`** field: the SLIP-44 coin type. Litecoin's is
2, testnet is 1. **WAM has no registration**, so the field is written out as a
comment rather than filled with a number.

Inventing one collides with whatever real coin owns it and derives every user's
keys onto a path no other wallet will ever look at. The same field is why
`komodo/coin-entry.json` carries no `derivation_path`.

Registration is a pull request to
[`satoshilabs/slips`](https://github.com/satoshilabs/slips) adding a line to
`slip-0044.md`, in the founder's name. Their queue is measured in weeks, so it
is worth opening early and separately from any listing — it blocks BasicSwap,
it blocks hardware wallet support, and it blocks the Komodo field, and none of
those can start until a number exists.

**Ask BasicSwap in the reply whether they will take the pull request with the
registration pending**, since everything else in it is complete. That is a
question with two possible answers and both are useful; guessing at it is not.

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

## The `bip44` field, and what is still pending

Their params dict carries the SLIP-44 coin type. Litecoin's is 2; testnet is 1
for every chain. Ours says **5718349**, which is `0x57414D` — `WAM` in ASCII,
the convention Wanchain used one number above at `0x57414E`.

It is not invented. `wamd` already derives there: a wallet reports
`44h/5718349h`, `49h/5718349h`, `84h/5718349h` and `86h/5718349h`. The field
describes the daemon BasicSwap will run, which is the only thing it can
honestly describe. The number is declared once in `src/wam/wam-params.h`, and
`scripts/audit_repo.sh` rejects any file here that disagrees with it.

**Registration with [`satoshilabs/slips`](https://github.com/satoshilabs/slips)
was granted on 2026-08-26** — satoshilabs/slips PR #2051, merged. Say that in the pull
request rather than letting them discover it. If a different number is
assigned, it changes in one place and every wallet made in the meantime is
discarded: free today, ruinous after mainnet.

**Worth asking them directly:** whether they will merge with the registration
pending, or would rather wait for it. Both answers are useful and neither is
worth guessing.

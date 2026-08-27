# BasicSwap — what a submission needs

BasicSwap replied to the enquiry sent 2026-08-18 and pointed at a GitHub
repository: [`tecnovert/basicswap`](https://github.com/tecnovert/basicswap).
The submission went there, as PR #2, on 2026-08-21.

**That is not where the project is developed, and it cost six days of
silence.** Checked on 2026-08-27:

| | last upstream commit | stars |
|---|---|---|
| `tecnovert/basicswap` | 2026-07-17 | 0 (a fork) |
| `basicswap/basicswap` | 2026-08-25 | 322 |

tecnovert is the author, and the repository he named is his own copy — it is
a fork of `basicswap/basicswap` and has received no development in six
weeks. Its "pushed today" timestamp was our own branch, not theirs.

There was nothing wrong with taking a maintainer at his word; the repository
he named simply stopped being the one that moves. The submission belongs in
`basicswap/basicswap`, and `scripts/prepare_listing_pr.sh` now stages it
there. The two repositories are in one fork network, so the same branch
opens against either without re-pushing anything.

The lesson is smaller than the six days: a named repository is a fact with a
date on it, and it is worth checking that the fact is still true before
waiting on an answer from it.

## What happened when it reached the right repository

`basicswap/basicswap#701`, opened 2026-08-27 with four files and 88 lines on
top of their current master. Closed the same day:

    nahuhh: closed: "Mainnet is scheduled for 2026-09-15"

Read it exactly as written. There was no review, no comment on any line, and
nothing said about the code -- they quoted our own sentence back. BasicSwap
does not add a coin whose chain has not launched, which is the same
condition Komodo has, and it is a reasonable one: an integration for a chain
that never opens is dead code they carry.

So the correct entry for this venue is not *submitted and waiting*. It is
**ready, and blocked on 15 September** -- the same shelf as Komodo. The
branch stays: it is one commit on their master and reopening #701 after
launch costs nothing.

Worth keeping in mind for the venues still open. Bisq, Haveno and Block DX
have not said this, but none of them has said the opposite either, and the
honest expectation is that a live chain is what unlocks all of them.

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

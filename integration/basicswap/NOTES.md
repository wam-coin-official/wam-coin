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

## Where the submission stands

`basicswap/basicswap#701`, opened 2026-08-27, closed the same day:

    nahuhh: closed: "Mainnet is scheduled for 2026-09-15"

No review, no comment on the code. They do not add a coin whose chain has
not launched. That was not among the requirements we were given, and it is
a fair rule anyway.

Written down for one practical reason: do not resubmit before 15 September.
The branch is a single commit on their current master, so reopening #701
after launch costs nothing and wastes nobody's time twice. Komodo waits on
the same condition.

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
was granted on 2026-08-26** — PR #2051, merged. The number is settled: nothing
here is waiting on an assignment, and nothing downstream can be invalidated by
one arriving differently. Say it in the pull request rather than letting them
discover it.

# Reporting a security issue

**Email: wam.coin.official@proton.me**

Please do not open a public issue for a security problem. Do not post it in the
Discord, and do not describe it on a forum. A consensus bug that is public
before it is fixed is a bug every node on the network is exposed to at once.

You will get an acknowledgement. If you do not hear anything within 72 hours,
send the mail again — assume it was lost, not ignored.

---

## What counts

Anything that would let someone:

* create WAM outside the emission schedule, or spend coins they do not own
* make honest nodes disagree about which chain is valid
* crash or stall a node from the network, or from a crafted block or transaction
* take a block reward that the treasury rule reserves, or bypass the time locks
  on the founder reserve
* steal from a mining pool built on `pool/`, or from a miner running `miner/`

Also worth reporting, though less urgent: a way to make the node leak
information about its wallet or its peers, and anything in `scripts/` that
could expose a private key.

Denial of service that requires more resources than it costs the attacker is
interesting. A report that amounts to "I sent 10 Gbit/s at it" is not.

## What to send

Enough to reproduce it. A patch is welcome but not required — a clear
description of the mechanism is worth more than a proof of concept we cannot
follow. If you have exploit code, send it; it will not be published.

State whether you want to be credited, and how.

## What happens next

There is no bug bounty. This project has no revenue and does not pretend
otherwise; a promise of payment we could not keep would be worse than saying so
plainly. What you will get is: a real answer from someone who read your report,
credit in the release notes if you want it, and a fix.

For anything that affects consensus or funds, the fix is written and tested
before it is described publicly. Once it is released, the report is published
in full, including the timeline and the name of whoever found it.

## Scope

This repository: the node (`src/`), the reference miner (`miner/`), the mining
pool (`pool/`), the explorer (`explorer/`), and the tooling in `scripts/`.

WAM is a fork of Bitcoin Core v28.1. A vulnerability in unmodified upstream code
should go to [Bitcoin Core's security process](https://bitcoincore.org/en/contact/)
first — they maintain it, and every fork including this one benefits from
disclosure to them. Send it here too if you believe WAM's changes make it worse.

## PGP

Not yet. Mail is accepted in plain text today; if you need encryption before
sending, say so in a first message with no details and a key will be published
and pointed to from this file.

### The signing key

When that key exists, its fingerprint goes here — on this line, in this file,
in this repository, and in no other place:

```
(no key has been published yet)
```

That matters beyond encrypted mail. [CHANNELS.txt](CHANNELS.txt) lists the
project's official channels, and a list of accounts that vouch for each
other is only as strong as the weakest of them: take one, repoint it at three
impostors, and the mutual linking now argues *for* the attacker. A detached
signature over CHANNELS.txt removes that. The reader stops needing to trust
any account and only needs one fingerprint, checked here.

Until the ceremony is held there is no signature, and this file says so rather
than implying a protection that does not exist. Anyone quoting a WAM
fingerprint from anywhere other than this file is quoting an invention.

---

*Last reviewed: 2026-08-11*

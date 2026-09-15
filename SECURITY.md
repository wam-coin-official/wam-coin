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

**The published tiers, paid in mainnet WAM.** These were announced before
launch, on BitcoinTalk and in the channels:

| | |
|---|---|
| Consensus split, inflation beyond the 22,000,000 cap, or theft of pool funds | 50,000 WAM |
| Remote crash, or a way to steal another miner's shares | 10,000 WAM |
| Everything else accepted | 1,000 WAM |

They are a floor and not a ceiling: a finding that matters more than its rung
can be paid more than its rung, and if that happens it will be said plainly
that it was a judgement and not a tier.

This file said the opposite of all of it until 2026-09-14 — "there is no bug
bounty" — while three other places in the repository said "there is a bounty"
and linked here. A reviewer followed our own sentence to our own file and found
it contradicted. He was right and the file was wrong.

**Nothing has been paid yet, and how it will be paid is not settled.** Between
14 and 15 September this paragraph claimed the opposite: that 1,000 WAM had
already been paid to the reviewer who found the pool API leaking payout
addresses, bought from a miner at a price the miners set in public, with the
offers, the price and the transaction published. None of that had happened.
Mainnet did not exist when the sentence was written, so there were no mainnet
coins to pay with and no price for anyone to have set. It was written here in
error and stood for a day, including on wamcoin.org/security.

What is true as of 15 September 2026: two findings are accepted and unpaid —
the pool API leak, and a pool accounting fault that could credit a matured
block more than once. The reserve the announcement named as the source is
locked by consensus until 2027-09-15, which anybody can verify from block 0,
so the source has to be something else and the founder has not yet said what.
When each is paid, the amount, the reason for the amount and the transaction id
will be published here, and not before.

Alongside it, and worth more in most cases: a real answer from someone who
read your report, credit in the release notes in whatever name you choose, and
a fix.

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

## The signing key

Its fingerprint goes here — on this line, in this file, in this repository,
and in no other place:

```
4BD4 A8D3 AFD4 3F5C BCB5  00E2 3798 462F E00A DBA4
```

```
WAM Coin (release signing) <wam.coin.official@proton.me>
RSA 4096 · created 2026-09-03 · expires 2031-09-02
```

The public key is [SIGNING-KEY.asc](SIGNING-KEY.asc) in this repository.

**Anyone quoting a WAM fingerprint from anywhere other than this file is
quoting an invention.** Not from an email, not from a chat message, not from a
forum post, and not from a copy of this repository hosted somewhere else.
Check it here, on GitHub, over HTTPS.

### What it signs, and what that is worth

Every release carries `SHA256SUMS` and `SHA256SUMS.asc`. The first lists the
hash of each file; the second is a signature over that list.

A checksum file on its own protects against a corrupted download and nothing
else: whoever can replace the binary can replace the list beside it, and both
will agree. The signature is what a stranger cannot forge without this key.

To check a download:

```
gpg --import SIGNING-KEY.asc
gpg --verify SHA256SUMS.asc SHA256SUMS
curl -LO https://github.com/wam-coin-official/wam-coin/releases/download/v0.1.8/SHA256SUMS.asc
curl -LO https://raw.githubusercontent.com/wam-coin-official/wam-coin/main/scripts/verify_release.sh
curl -LO https://raw.githubusercontent.com/wam-coin-official/wam-coin/main/SIGNING-KEY.asc
bash verify_release.sh .
```

or run [scripts/verify_release.sh](scripts/verify_release.sh), which does the
three and refuses to say "ok" unless all three pass.

`gpg --verify` printing `Good signature` with a `WARNING: This key is not
certified with a trusted signature` is the normal and expected result. It
means the signature is genuine and that you have not personally vouched for
the key — which nobody should, on first contact. The fingerprint above is what
you check instead.

### The key is not on any server this project runs

It was generated on the founder's own machine and exists in two places: that
machine, and an offline backup. No node, no seed, no pool and no build server
has ever held it. A server that is compromised cannot be used to sign a
release, which is the entire point of keeping it off them.

A revocation certificate was created in the same session and is stored apart
from the key. If this fingerprint ever changes, or a revocation is published,
treat every release signed after that moment as untrusted until this file
says otherwise.

### CHANNELS.txt

[CHANNELS.txt](CHANNELS.txt) lists the project's official channels, and a list
of accounts that vouch for each other is only as strong as the weakest of
them: take one, repoint it at three impostors, and the mutual linking now
argues *for* the attacker. A detached signature over CHANNELS.txt removes
that. The reader stops needing to trust any account and only needs the one
fingerprint above.

## PGP mail

Mail is accepted in plain text. The key above is for signing releases; if you
need to encrypt a report before sending it, say so in a first message with no
details.

---

*Last reviewed: 2026-08-11*

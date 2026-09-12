# v0.1.8 — Windows and macOS, 12 September 2026

Four drafts for four places. **Nobody has posted them; the founder posts by
hand.** Sparks60 asked for Windows and macOS in Discord, so that draft
answers him by name, in the thread where he asked.

| File | Where | Format |
|---|---|---|
| `bitcointalk.txt` | the existing WAM topic in [Altcoin Announcements](https://bitcointalk.org/index.php?board=159.0) | BBCode, one reply |
| `telegram.txt` | [t.me/wam_coin_updates](https://t.me/wam_coin_updates) | English, then Arabic |
| `discord.txt` | [discord.gg/Gxvmrjy9Qb](https://discord.gg/Gxvmrjy9Qb) | three messages, each under the 2000 cap |
| `x.txt` | [x.com/WAMCoinCore](https://x.com/WAMCoinCore) | a thread of 8, plus two Arabic posts |

Post BitcoinTalk first. It is the one that gets replies and the one the
others can link to.

## Every figure, and where it was read from

Nothing here is aspirational. Each number was read out of the running system
on 12 September, and each can be re-read:

```
heights 0, 1, 5000, 6000   scripts/test/test_platform_consensus.sh, the gate
                           in .github/workflows/platform-build.yml
1.88 kH/s, 8 of 24 cores   the miner's own stats line, Windows 11
10 accepted, 0 rejected    the same
block 8478                 the pool journal on the France host:
                           "BLOCK CANDIDATE at height 8478 by ...win11"
                           then "BLOCK 8478 ACCEPTED"
Bearfoos.A!ml              Get-MpThreatDetection, ThreatID 2147731250,
                           02:53:21 local, fourteen seconds into the run
six release assets         the GitHub API, not the packaging script
the correction             measured by downloading the page from a seed
                           with the CDN cache bypassed: BADSIG, then GOODSIG
```

## What the posts do not say

**No countries, no addresses, no operator names.** One operator per country
means naming a country names the person, to anyone who can watch the
network, and none of them agreed to be named. That rule has not changed.

**No hashrate for the network as a whole.** The figure quoted is one
desktop's, labelled as one desktop's. The network total is smaller than a
single machine and publishing it invites the arithmetic an attacker
performs; `docs/ROADMAP.md` section 5.0 is why.

**Nothing that ages.** No countdown, no "in three days". The date says the
same thing and stays true. The chain height moves every two minutes, so no
post quotes a current height — 8478 is quoted as the block the miner found,
which is a fixed historical fact, not a status.

## The correction is in three of the four

It would have been easy to leave out. For about seven hours the release page
served a checksum list that did not match its own signature, so a stranger
following our own instructions was told the signature was invalid about a
release that was fine — which is the worst sentence this project can put in
front of somebody deciding whether to trust it.

Anyone who checked in that window and walked away is owed the correction,
and they are exactly the people careful enough to have checked. Saying it
costs a paragraph; not saying it means a person who did the right thing is
left believing we shipped a forged file.

It is not in `x.txt`. A thread of eight is not where a seven-hour signature
fault gets explained properly, and a half-explanation there would read as
either a boast or an alarm. The three places that carry it are the three
where the full reason fits.

## Never write a bare filename that ends in a TLD

`scripts/check_post_text.py` enforces this and it runs in the sweep. The
same fault reached an operator alarm on 12 September -- "the key in
SECURITY.md", which Telegram turned into a link to a Moldovan shop -- so
there is now a matching check for alert text in
`scripts/test/test_alert_text.py`. Two checks because they read different
files, not because the rule differs.

Every reference in these drafts is a full `https://` URL.

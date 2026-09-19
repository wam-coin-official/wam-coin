# v0.1.9 — what was posted, and why it says what it says

Written 2026-09-19, four days and twelve hours after mainnet opened. Every
figure in these four files was measured that day, not recalled:

| | |
|---|---|
| height | 3,149 |
| network hash rate | 412,686 H/s |
| difficulty | 0.0104 |
| mined | 157,450 WAM of a 22,000,000 cap |
| distinct finders, life of chain | 17 |
| largest finder | 61.2% |
| our pool | 0% fee, ~96 kH/s, 852 blocks confirmed |

**The mining invitation is the point; the release is secondary.** The bot
announced v0.1.9 on its own when the tag was published, so these texts exist
for the other thing: concentration is at 61.2%, and the only thing that
moves it is miners choosing a different pool. Silence would leave that
number where it is.

**The concentration figure leads, and is not dressed up.** It is already
published permanently on the explorer by the founder's own commitment, so
repeating it costs nothing an attacker did not already have — anyone who can
attack this chain reads `getnetworkhashps`, not our Telegram. What silence
would cost is the miners.

**It is framed as arithmetic, not as distress.** "We are at 61% and need
help" invites vandalism and reads as desperation to the miner we want. The
number is stated, the remedy is stated, and no one is begged.

**The release is described as NOT mandatory, in every one of the four.** A
v0.1.8 node accepts identical blocks. Telling people to upgrade urgently
would spend the one warning that has to be believed later.

**"Forty more workers" is a measured figure, not a slogan.** The largest pool
runs 224.89 kH/s from three addresses across thirteen workers — about
17.3 kH/s each, server-class hardware. Our average worker is 2.9 kH/s. For
the rest of the network to exceed them takes roughly 117 kH/s, which is
about forty workers of our size.

**No price, no listing, no presale, in all four.** Unchanged, and stated
plainly so nobody arrives expecting one.

`scripts/check_post_text.py` refused the first draft: `SECURITY.md` is a
hostname to Telegram, X and most forums, on a registry we do not control. It
is a full URL now.

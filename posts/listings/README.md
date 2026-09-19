# Where every listing request stands

Measured from the GitHub API on 2026-09-19, not recalled. Nine requests were
opened; this is what became of them and what, if anything, is owed.

| repo | # | state | what happened |
|---|---|---|---|
| satoshilabs/slips | 2051 | **merged** | coin type 5718349 and prefixes wam/twam/wamrt, 26 August |
| blocknetdx/blockchain-configuration-files | 197 | **open** | tryiou is folding it into a cleanup batch and said he will bump us |
| KomodoPlatform/coins | 21 | **open** | no comments at all since 29 August |
| GLEECBTC/coins | 1975 | **open** | **waiting on us** — see below |
| basicswap/basicswap | 701 | closed | "Mainnet is scheduled for 2026-09-15" — a deferral, not a refusal |
| bisq-network/bisq | 8030 | closed | he could not find the project — only the BEP-20 gaming token — and the ticker conflicts with it |
| haveno-dex/haveno | 2528 | closed | "We only consider coins with market traction / price" — the only market condition anyone set |
| bisq #8028, haveno #2527 | | closed | replaced by our own later PRs, no comments, not refusals |

## The one that is our fault

**GLEEC #1975.** cipig asked on 30 August: *"What about the 2 electrums? Do we
need to wait till 15.09.?"* He was told yes. 15.09 came, the servers moved to
mainnet, and nobody went back to him. Four days of an open request waiting on
a date that had already passed. `gleec-1975.txt` is the reply and it should go
first.

## The one worth reopening

**BasicSwap.** The closure had exactly one stated reason and it was the launch
date. Nothing was said about the coin, the code or the policy.
`basicswap-701-reopen.txt` reports that the condition is met and does not
argue with anything.

## Bisq: it was not a policy refusal, and this file said it was

Read whole rather than summarised, both of HenrikJannsen's comments turn on
one thing -- he could not find us.

> I do not see any project related to WAM but an existing coin
> [coingecko.com/en/coins/wam]. Bisq did not add new altcoins anymore, though
> with the BIP110 hardfork there might be case to reconsider that.
> -- 22 August

> I fear the request will not get support and as the ticker symbol conflicts
> thats another issue. As far I am aware the BIP110 Blake based fork coin
> will not have replay protection and therefor will not get added to Bisq as
> well as it would put users at risk. I will close that issue.
> -- 29 August

Three things this file got wrong on 19 September and are corrected here:

**"Bisq does not add new altcoins" was not the final word.** It is qualified
in the same sentence -- *"though with the BIP110 hardfork there might be case
to reconsider that"*.

**The objection that repeats in both comments is the identity collision.**
First he cannot find a project, only the BEP-20 gaming token; then the ticker
conflicts -- with that same token.

**And the flat "will not get added" is not about WAM at all.** It is about the
BIP110 Blake fork coin, a different project, refused for having no replay
protection. Attributing that sentence to us was a misreading.

What changed since 29 August is exactly the thing he could not find:

| | |
|---|---|
| a live chain | mainnet since 2026-09-15, height 3,307, 47 peers |
| an identity that is not the gaming token | SLIP-0044 coin type **5718349**, SLIP-0173 prefixes wam / twam / wamrt, merged 26 August |
| something to run | signed releases for Linux, Windows and macOS |
| something to check it with | a public explorer, and a concentration figure published whether it flatters us or not |

`bisq-new.txt` is written on that basis. It leads with what can be verified,
and it addresses the ticker head-on instead of hoping nobody mentions it --
because that part has not changed and pretending otherwise would be the
fastest way to deserve a third closure.

## The one that should NOT be reopened

**Haveno** closed #2528 with "we only consider coins with market traction /
price". Of every request this project has opened, that is the only one that
asked for a market, and WAM has none by design: this project does not pay for
listings, does not arrange a price, and says so in public. Reopening asks a
maintainer to make an exception to the single criterion he named, and the
answer would be the same.

(#2527 is not a refusal; it has no comments and was replaced by #2528 the
next day. The same is true of bisq #8028, replaced by #8030.)

It becomes worth revisiting when the reason itself changes -- a market that
exists because people want the coin, not because we arranged one.

## All six, ready. The founder picks the day.

A dormant request dies of silence, not of refusal. Three of these are open
and nobody has said no; two people are waiting on something that has already
happened, and one maintainer said he would call and has not yet. A short
message that the chain is live is what revives them.

Send in this order. Each stands alone -- skipping one does not break another.

| | file | where | why now |
|---|---|---|---|
| 1 | `gleec-1975.txt` | comment on the open PR | **overdue.** He asked whether to wait for 15.09 and nobody went back to him |
| 2 | `blockdx-197.txt` | comment on the open PR | the entry moved to v0.1.9, as promised in that thread in August |
| 3 | `komodo-21.txt` | comment on the open PR | open since 29 August with zero comments — give a reviewer a reason to look |
| 4 | `basicswap-701-reopen.txt` | **new** PR | closed for one reason, the launch date, and it has passed |
| 5 | `bisq-new.txt` | **new** PR | closed because he could not find the project; now he can |
| 6 | `haveno-2528.txt` | comment on the closed PR | asks for nothing. Send only if the record there is worth updating |

Every figure in all six was measured at 2026-09-19T18:30:44Z. **If they are
sent more than a day or two later, re-measure first** — height, peers and the
mined total move, and a stale number in a public thread costs more than it
saves. `scripts/check_post_text.py` must pass before any of them goes out.

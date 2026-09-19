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
| bisq-network/bisq | 8028, 8030 | closed | policy: "Bisq did not add new altcoins anymore", plus a ticker conflict |
| haveno-dex/haveno | 2527, 2528 | closed | "We only consider coins with market traction / price" |

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

## The two that should NOT be reopened

**Bisq** closed on policy — they do not add new altcoins — and separately
raised a ticker conflict. Neither is a fact about WAM that changed on
15 September. A new request asks a maintainer to break a rule he has just
stated in writing, and the record there is currently good: the identity
confusion with the BEP-20 gaming token was corrected, the closure was
accepted without argument, and the SLIP registration was left in the thread
for whoever reads it later. That is worth more than a second refusal.

**Haveno** closed with "we only consider coins with market traction / price".
WAM has neither, by design, and this project does not pay for listings or
manufacture a price. Reopening would be asking them to make an exception for
a coin that still does not meet the only criterion they named. The answer
would be the same and the asking would cost the good record.

Both become worth revisiting if the reason itself changes — a policy shift,
or a market that exists without us arranging one. Not before.

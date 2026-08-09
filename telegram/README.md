# The announcement bot

Posts what the chain is doing to a Telegram channel. Nothing it says is
written by a person, and everything it says can be checked against a node.

```bash
cp telegram/config.example.json telegram/config.json
$EDITOR telegram/config.json          # bot token, chat id, RPC credentials
node telegram/bot.js --once --dry-run # prints what it would send
node telegram/bot.js                  # runs
```

## What it posts

| | when |
|---|---|
| status | once a day: height, hashrate, block reward, supply, next halving, next key rotation |
| halving | the moment the block subsidy changes |
| key rotation | when the RandomX epoch turns over and every miner rebuilds its dataset |
| release | when a new version appears on GitHub |
| milestone | round heights, and round millions of supply |
| **stall** | when no block has arrived for an hour |

It does **not** post commits. Anyone who wants those has GitHub's Watch
button, and a stream of "fix X" messages tells a reader who is not a developer
that a project is unstable, when careful maintenance means the opposite.

## Why a bot at all

The founder of this project makes no public statements. That is deliberate. It
also leaves a channel with nothing in it, and a silent channel reads as a dead
project — which is a false signal, and the most damaging kind.

So the chain speaks instead. Every figure is read over RPC and can be
reproduced by anyone running `wam-cli getsupplyinfo`. No opinions, no
forecasts, no price. Silence becomes a visible policy rather than an absence.

## The stall alert

Most projects announce good news and go quiet during an outage. This one says
`🔴 No new block for 63 minutes` in the same channel, automatically.

That is not self-flagellation. A channel that only carries good news is
advertising, and readers learn to discount it. A channel that reports its own
outages is a source. It also means the operator finds out from the same place
as everyone else, which is the right way round.

## Setup

**The bot token.** Message `@BotFather`, send `/newbot`, follow it. Add the
resulting bot to your channel as an administrator with permission to post, and
nothing else.

**The chat id.** For a public channel it is `@name`. For a private channel or
a group, post any message there and open
`https://api.telegram.org/bot<TOKEN>/getUpdates` — the id is the negative
number in `"chat":{"id":-100…}`.

**Keep `config.json` out of git.** It holds a token, which is a password for
the channel. It is already in `.gitignore`.

## Design notes

**No dependencies.** Two classes over Node's built-in `http` and `https`. A
process that holds a bot token and runs unattended should not also carry a
dependency tree that can be updated by strangers.

**No GitHub Actions.** The obvious alternative — a workflow that posts on
push — needs the bot token stored as a repository secret, putting the key to
the announcement channel inside a system that does not need it. This polls
GitHub's public releases API instead, unauthenticated, twelve times an hour
against a limit of sixty.

**State is a file, written atomically.** `state.json` remembers what has
already been announced. Without it a restart at the wrong moment announces the
same halving twice, and a bot that repeats itself stops being believed.

**Milestones passed while the bot was off are not announced.** Only ones
crossed between two observations. Starting the bot on a chain at height
500,000 should not produce a burst of congratulations for events that happened
last year.

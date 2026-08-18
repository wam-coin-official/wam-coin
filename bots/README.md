# The WAM announcement bot

One process reads the chain and posts what it finds to Telegram and Discord,
or to either alone.

```
node bots/announce.js --config /etc/wam/announce.json
node bots/announce.js --once --dry-run     # print, send nothing, write nothing
```

Set up with `bash bots/setup.sh`, which creates the user, asks for the
credentials without echoing them, verifies each one against its service, and
installs the systemd unit.

---

## What it posts

| | |
|---|---|
| Heartbeat | once a day: height, hashrate, supply, next halving |
| Halvings | the moment the block subsidy changes |
| Key rotations | when the RandomX epoch turns over |
| Releases | when a new version is published on GitHub |
| Milestones | round heights |
| Stalls | when no block has arrived for too long, and again when they resume |

Everything it says is a number read from a node over RPC, which anyone can
check against their own. No opinions, no price, and nothing that needs a person
to write it.

**It does not post commits.** Anyone who wants those has GitHub's Watch button,
and a stream of "fix X" messages tells a non-developer that a project is
unstable when the opposite is true.

**It does post stalls.** A channel that carries only good news is advertising;
one that reports its own outages is a source. It also means the operator learns
about a stopped chain from the same place everyone else does, which is the
right way round.

---

## How the two services stay identical

Messages are written once, in the neutral markup in `lib/markup.js`, and
rendered per service on the way out — HTML for Telegram, Markdown for Discord.
Nothing above that layer knows which services exist, so the two channels cannot
drift apart in content, and a message added later reaches both without work.

Escaping happens at the sink rather than where the message is built. It is a
property of the destination, not of the message, and the version that escaped
at construction required fifteen separate places to remember.

---

## Discord uses a webhook, not the bot token

A webhook posts to exactly one channel. It cannot read a message, list members,
remove anyone, or reach another channel. A bot token can do all four, and an
announcement needs none of them.

So the worst a leaked webhook can do is put nonsense in one channel, undone by
deleting it. A leaked bot token is the server.

Keep the bot registration for slash commands later — `/height`, `/supply` — 
which do need it. Announcements do not.

---

## Credentials

They live in `/etc/wam/announce.json`, mode 0600, owned by the bot's own user,
**outside this repository**. A secret inside a git working tree is one
`git add -A` away from being public.

`setup.sh` reads them with the terminal echo off, so they never appear on
screen, in `~/.bash_history`, or in the process list. It also offers to import
an existing bot config rather than have anyone retype a fourteen-digit channel
id — a mistyped id fails as "could not post", which sends you to check
permissions that were never wrong.

The bot refuses to start if the config is readable by anyone else.

---

## Tests

```
for f in bots/test/*.test.js; do node "$f"; done
```

49 of them. They cover the two things that are invisible until they matter: a
credential reaching a log, and a release note formatting an announcement it did
not write.

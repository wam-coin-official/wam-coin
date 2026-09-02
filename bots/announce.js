#!/usr/bin/env node
'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  The WAM announcement bot
// ===========================================================================
//
//      node bots/announce.js [--config FILE] [--once] [--dry-run]
//
//  WHAT IT IS FOR
//  --------------
//  The founder of this project does not make public statements. That is a
//  deliberate position and a defensible one, but it leaves a channel with
//  nothing in it, and a silent channel reads as a dead project.
//
//  So the chain speaks instead. Everything this bot posts is a number read
//  from a node over RPC, which anyone can check against their own node. No
//  opinions, no promises, no price -- and nothing that requires a human to
//  write it.
//
//  WHAT IT POSTS
//  -------------
//      a heartbeat        once a day: height, hashrate, supply, next halving
//      halvings           the moment the block subsidy changes
//      key rotations      when the RandomX epoch turns over
//      releases           when a new version is published on GitHub
//      milestones         round heights and round millions of supply
//      stalls             when no block has arrived for too long
//
//  That last one is the one nobody else does. A channel that only carries good
//  news is advertising; a channel that reports its own outages is a source. It
//  also means the operator learns about a stalled chain from the same place
//  everyone else does, which is the right way round.
//
//  It does NOT post commits. Anyone who wants those has GitHub's Watch button,
//  and a stream of "fix X" messages tells a non-developer that a project is
//  unstable when the opposite is true.
//
//  WHERE IT POSTS
//  --------------
//  Telegram, Discord, or both -- whichever the config names. Every message is
//  written once in the neutral markup from lib/markup.js and rendered per
//  service on the way out, so the two channels can never drift apart in
//  content, and a message added later needs no work to reach both.
//
//  Discord is reached through a webhook rather than a bot token. A webhook can
//  post to one channel and do nothing else: it cannot read messages, list
//  members, or touch another channel. An announcement needs none of those, and
//  a credential that cannot do them cannot be made to.

const fs = require('fs');
const path = require('path');

const { NodeRpc, latestRelease } = require('./lib/clients');
const { buildSinks } = require('./lib/sinks');
const { loadConfig } = require('./lib/config');
const { b, i, t, code, kbd, toTelegram, toDiscord, toPlain } = require('./lib/markup');

const COIN = 100000000;

// ---------------------------------------------------------------------------

function parseArgs(argv) {
    const out = { config: null, once: false, dry: false };
    for (let i = 2; i < argv.length; i++) {
        if (argv[i] === '--config' && argv[i + 1]) out.config = argv[++i];
        else if (argv[i] === '--once') out.once = true;
        else if (argv[i] === '--dry-run') out.dry = true;
        else if (argv[i] === '--help' || argv[i] === '-h') out.help = true;
    }
    return out;
}


// ---------------------------------------------------------------------------
// State. A flat file, written atomically: the bot must never announce the same
// halving twice because it was restarted at the wrong moment.
// ---------------------------------------------------------------------------

function loadState(file) {
    try {
        return JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
        return {};
    }
}

function saveState(file, state) {
    const tmp = `${file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
    fs.renameSync(tmp, file);
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

const num = (n) => Number(n).toLocaleString('en-US');

function wam(sat, dp = 2) {
    const v = Number(sat) / COIN;
    // Below the chosen precision, widen rather than render a real amount as
    // "0.00" -- deep into the halvings the subsidy is a handful of satoshi.
    if (v !== 0 && Math.abs(v) < 1 / 10 ** dp) {
        return v.toFixed(8).replace(/0+$/, '').replace(/\.$/, '');
    }
    return v.toLocaleString('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp });
}

function hashrate(hs) {
    if (!hs || hs <= 0) return '0 H/s';
    const units = ['H/s', 'kH/s', 'MH/s', 'GH/s', 'TH/s'];
    let i = 0;
    while (hs >= 1000 && i < units.length - 1) { hs /= 1000; i++; }
    return `${hs.toFixed(2)} ${units[i]}`;
}

function duration(seconds) {
    if (!Number.isFinite(seconds) || seconds <= 0) return '—';
    const d = Math.floor(seconds / 86400);
    if (d >= 365) return `~${(d / 365).toFixed(1)} years`;
    if (d >= 1)   return `~${d} days`;
    const h = Math.floor(seconds / 3600);
    if (h >= 1)   return `~${h} hours`;
    return `~${Math.max(1, Math.round(seconds / 60))} minutes`;
}

// ---------------------------------------------------------------------------
// Reading the chain
// ---------------------------------------------------------------------------

async function snapshot(rpc) {
    // getsupplyinfo carries the emission; the RandomX epoch lives in its own
    // RPC. Reaching for randomx_seedheight in getsupplyinfo, where it does not
    // exist, meant key rotations were silently never announced.
    const [chain, mining, supply, randomx] = await Promise.all([
        rpc.call('getblockchaininfo'),
        rpc.call('getmininginfo').catch(() => ({})),
        rpc.call('getsupplyinfo').catch(() => null),
        rpc.call('getrandomxinfo').catch(() => null)
    ]);

    const tipHeader = await rpc.call('getblockheader', [chain.bestblockhash]).catch(() => null);

    // Everything about emission comes from the node. Recomputing the halving
    // schedule locally is the mistake this project has now made four times.
    return {
        height: chain.blocks,
        chainName: chain.chain,
        difficulty: chain.difficulty,
        hashrate: mining.networkhashps || 0,
        tipTime: tipHeader ? tipHeader.time : null,
        supply,
        randomx
    };
}

// ---------------------------------------------------------------------------
// Messages
//
// Built in the neutral markup: b() for bold, i() for italic, t() for anything
// that came from outside this file. No service is named here, and none of these
// functions can produce broken output on one service while working on another.
// ---------------------------------------------------------------------------

/**
 * Which chain these numbers describe.
 *
 * Not decoration. A channel published before launch shows testnet figures, and
 * a reader who assumes they are mainnet concludes the coin is already live at
 * height 198. Every message says which chain it came from, and anything that
 * is not mainnet says so loudly enough that it cannot be skimmed past.
 */
function networkLabel(chainName) {
    switch (chainName) {
    case 'main':    return null;                          // no banner needed
    case 'test':    return `\u{1F9EA} ${b('TESTNET')} — coins here have no value`;
    case 'regtest': return `\u{1F527} ${b('REGTEST')} — a private test chain`;
    default:        return `⚠️ ${b(String(chainName).toUpperCase())}`;
    }
}

function heartbeat(s, cfg) {
    const sup = s.supply || {};
    const banner = networkLabel(s.chainName);
    const lines = [
        `\u{1F7E2} ${b('WAM Network')}`,
        ...(banner ? [banner] : []),
        ``,
        `${b('Height')}        ${num(s.height)}`,
        `${b('Hashrate')}      ${hashrate(s.hashrate)}`
    ];

    if (sup.block_subsidy !== undefined) {
        const subsidy = Math.round(Number(sup.block_subsidy) * COIN);
        const treasury = Math.round(Number(sup.treasury_subsidy || 0) * COIN);
        lines.push(`${b('Block reward')}  ${wam(subsidy)} WAM` +
                   (treasury > 0 ? `  (${wam(subsidy - treasury)} miner + ${wam(treasury)} treasury)` : ''));
    }

    if (sup.circulating !== undefined && sup.max_supply !== undefined) {
        const pct = (Number(sup.circulating) / Number(sup.max_supply) * 100).toFixed(2);
        lines.push(`${b('Supply')}        ${num(Math.round(Number(sup.circulating)))} / ` +
                   `${num(Math.round(Number(sup.max_supply)))}  (${pct}%)`);
    }

    // Do not promise a halving that can no longer happen. Once the subsidy has
    // decayed to zero the node still reports a next_halving_height, but there
    // is nothing left to halve.
    const subsidySat = sup.block_subsidy !== undefined
        ? Math.round(Number(sup.block_subsidy) * COIN) : null;

    if (subsidySat === 0) {
        lines.push(`${b('Emission')}      complete — miners are paid by fees alone`);
    } else if (sup.blocks_until_halving > 0) {
        lines.push(`${b('Next halving')}  in ${num(sup.blocks_until_halving)} blocks ` +
                   `(${duration(sup.blocks_until_halving * 120)})`);
    }

    const rx = s.randomx;
    if (rx && rx.blocks_until_rotation > 0) {
        lines.push(`${b('RandomX key')}   rotates in ${num(rx.blocks_until_rotation)} blocks`);
    }

    if (cfg.explorerUrl) lines.push(``, t(cfg.explorerUrl));
    return lines.join('\n');
}

function halvingMessage(before, after, height) {
    return [
        `⛏ ${b('The block reward has halved')}`,
        ``,
        `At height ${num(height)} the subsidy went from`,
        `${b(wam(before) + ' WAM')} to ${b(wam(after) + ' WAM')}.`,
        ``,
        `This is written into consensus and happens every 200,000 blocks.`,
        `No decision was taken and none could be.`
    ].join('\n');
}

function rotationMessage(seedHeight, height) {
    return [
        `\u{1F511} ${b('RandomX key rotated')}`,
        ``,
        `From height ${num(height)} the proof-of-work key is derived from`,
        `block ${num(seedHeight)}.`,
        ``,
        `Every miner rebuilds its dataset now; a brief dip in network`,
        `hashrate over the next few minutes is expected, not a fault.`
    ].join('\n');
}

/**
 * Turn a GitHub release body into marked-up message text.
 *
 * The body is Markdown written for GitHub's own renderer. It used to be passed
 * through untouched, which is why the v0.1.1 announcement arrived on Telegram
 * showing three literal backticks above and below the verification command:
 * Telegram messages are sent as HTML, where a fence means nothing at all.
 *
 * Fenced blocks become code() and inline spans become kbd(), so each service
 * renders them in its own syntax. Every branch below emits a matched pair of
 * marks, so an unbalanced fence in someone's release note -- or a body cut off
 * mid-block by the line limit -- can never leave a tag hanging open.
 */
function fromMarkdown(text) {
    // Odd indexes are the insides of fenced blocks; even indexes are prose.
    return String(text || '')
        .split(/```[a-zA-Z0-9_-]*\n?/)
        .map((part, idx) => {
            if (idx % 2 === 1) return code(part.replace(/\n+$/, ''));
            // Same alternation again, for single-backtick spans in prose.
            return part.split(/`([^`\n]+)`/)
                .map((seg, j) => (j % 2 === 1 ? kbd(seg) : t(seg)))
                .join('');
        })
        .join('');
}

// A release whose notes begin a line with "MANDATORY:" is one that changes a
// consensus rule. Everything after the colon, on that line, is the reason.
//
//     MANDATORY: every earlier release enforces a different treasury address
//
// WHY THIS EXISTS
//
// v0.1.5 changed the mainnet treasury address, which is consensus. A node
// left on v0.1.4 will reject every valid block on 15 September and fork
// itself off at height 1 -- and it will not say so. It syncs, it mines, it
// reports itself healthy, alone on a chain nobody else is on.
//
// The bot announced that release in exactly the tone it announces every
// other: "a new version exists, here is how to verify it". It cannot tell
// the difference, because nothing told it. Somebody then has to remember to
// write the warning by hand, and the day they forget is the day it matters.
//
// So the release notes carry the distinction and the bot repeats it loudly.
const MANDATORY = /^[ \t>*_]*MANDATORY:[ \t]*(.+)$/im;

function releaseMessage(release) {
    const raw = String(release.body || '');
    const flag = raw.match(MANDATORY);

    // The marker line is removed from the body it is quoted from, so the
    // reason is not printed twice.
    const cleaned = flag ? raw.replace(MANDATORY, '').replace(/^\s*\n/, '') : raw;

    // Truncated by line before conversion, never after: the marks are single
    // characters and slicing a rendered string can cut one off from its pair.
    const body = fromMarkdown(cleaned.split('\n').slice(0, 12).join('\n'));

    return [
        flag
            // Above the title, not below it: a warning under the fold is a
            // warning nobody read.
            ? `\u{26A0}\u{FE0F} ${b('UPDATE REQUIRED')} \u{2014} ${b(release.name || release.tag)}`
            : `\u{1F680} ${b(release.name || release.tag)}`,
        ...(flag ? [
            ``,
            b('This release changes a consensus rule.'),
            t(flag[1].trim()),
            t('A node left on an earlier version will be rejected by the network '
              + 'and will not be told. It keeps running, and mines a chain with '
              + 'nobody else on it.'),
        ] : []),
        // Said plainly rather than left for the reader to notice on the page.
        // Every release before 1.0 is a pre-release, and a channel that
        // announces one without saying so is describing the project as further
        // along than it is.
        ...(release.prerelease ? [i('Pre-release — testnet software.')] : []),
        ``,
        body,
        ``,
        t(release.url),
        ``,
        i('Verify the checksums before you run it.')
    ].join('\n');
}

function milestoneMessage(kind, value) {
    if (kind === 'height') {
        return `\u{1F4CD} ${b('Block ' + num(value))}\n\nThe chain has reached height ${num(value)}.`;
    }
    return `\u{1F4CD} ${b(num(value) + ' WAM mined')}\n\nOut of a hard cap of 22,000,000.`;
}

function stallMessage(minutes, height) {
    return [
        `\u{1F534} ${b('No new block for ' + minutes + ' minutes')}`,
        ``,
        `The chain is still at height ${num(height)}. The target is one block`,
        `every two minutes.`,
        ``,
        `This usually means the network hashrate has dropped. It is posted`,
        `here because a channel that only reports good news is advertising.`
    ].join('\n');
}

function recoveredMessage(height, minutes) {
    return `\u{1F7E2} ${b('Blocks are arriving again')}\n\nHeight ${num(height)}, after ${minutes} minutes.`;
}

// ---------------------------------------------------------------------------
// One pass
// ---------------------------------------------------------------------------

async function tick(cfg, rpc, state, log) {
    const s = await snapshot(rpc);
    const now = Date.now();
    const out = [];

    const sup = s.supply || {};
    const subsidy = sup.block_subsidy !== undefined
        ? Math.round(Number(sup.block_subsidy) * COIN) : null;

    // ---- halving -----------------------------------------------------------
    if (subsidy !== null && state.lastSubsidy !== undefined && subsidy !== state.lastSubsidy) {
        // Only announce a decrease. An increase would mean the node changed
        // chains under us, which is a bug report, not an announcement.
        if (subsidy < state.lastSubsidy) {
            out.push(halvingMessage(state.lastSubsidy, subsidy, s.height));
        } else {
            log(`subsidy went UP (${state.lastSubsidy} -> ${subsidy}); not announcing`);
        }
    }
    if (subsidy !== null) state.lastSubsidy = subsidy;

    // ---- RandomX key -------------------------------------------------------
    const seedHeight = s.randomx ? s.randomx.seed_height : null;
    if (seedHeight !== null && state.lastSeedHeight !== undefined && seedHeight !== state.lastSeedHeight) {
        out.push(rotationMessage(seedHeight, s.height));
    }
    if (seedHeight !== null) state.lastSeedHeight = seedHeight;

    // ---- milestones --------------------------------------------------------
    const seen = new Set(state.milestonesSeen || []);
    for (const h of cfg.milestoneHeights) {
        if (s.height >= h && !seen.has(`h${h}`)) {
            // Do not shout about milestones the chain passed while the bot was
            // switched off; only ones crossed since the last observation.
            if (state.lastHeight !== undefined && state.lastHeight < h) {
                out.push(milestoneMessage('height', h));
            }
            seen.add(`h${h}`);
        }
    }
    state.milestonesSeen = [...seen];

    // ---- stall -------------------------------------------------------------
    if (s.height === state.lastHeight) {
        const stalledFor = Math.round((now - (state.lastHeightAt || now)) / 60000);
        if (stalledFor >= cfg.stallMinutes && !state.stallAnnounced) {
            out.push(stallMessage(stalledFor, s.height));
            state.stallAnnounced = true;
        }
    } else {
        if (state.stallAnnounced) {
            const wasDown = Math.round((now - (state.lastHeightAt || now)) / 60000);
            out.push(recoveredMessage(s.height, wasDown));
            state.stallAnnounced = false;
        }
        state.lastHeight = s.height;
        state.lastHeightAt = now;
    }

    // ---- releases ----------------------------------------------------------
    if (cfg.githubRepo) {
        const release = await latestRelease(cfg.githubRepo);
        if (release && release.tag && release.tag !== state.lastReleaseTag) {
            // The first observation is not news: it is whatever was already
            // published before the bot existed.
            if (state.lastReleaseTag !== undefined) out.push(releaseMessage(release));
            state.lastReleaseTag = release.tag;
        }
    }

    // ---- heartbeat ---------------------------------------------------------
    //
    // At a fixed hour, not "heartbeatHours since the last one".
    //
    // The interval version drifts. Every restart of this bot -- a reboot, a
    // deploy, a crash -- pushes the daily post later by however long it was
    // down, and it never comes back. By 2 September the post was landing at
    // 04:53 UTC, which is before dawn where the founder is, so the channel
    // looked silent to him for a whole day while the bot was working
    // perfectly. He watches this channel to see that the test network is
    // alive, and other people in it do the same. A daily post nobody is awake
    // for does not do that job.
    //
    // A fixed hour also makes silence mean something. If the post is due at a
    // known time and does not arrive, that is a fact anyone in the channel can
    // notice, without knowing anything about the machine.
    const beatHour = cfg.heartbeatHourUtc ?? 12;
    const last = state.lastHeartbeatAt || 0;
    const d = new Date(now);
    const dueToday = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(),
                              beatHour, 0, 0);
    // Due if today's slot has passed and nothing has been sent since it. The
    // "since it" is what stops a restart at 12:05 from posting a second time.
    if (now >= dueToday && last < dueToday) {
        out.push(heartbeat(s, cfg));
        state.lastHeartbeatAt = now;
    } else if (last && now - last >= 36 * 3600 * 1000) {
        // A machine that was off across its slot would otherwise wait for
        // tomorrow. Thirty-six hours of silence in a public channel is long
        // enough to look like a dead project, so it speaks late rather than
        // not at all.
        out.push(heartbeat(s, cfg));
        state.lastHeartbeatAt = now;
    }
    state.nextHeartbeatDueAt = (now >= dueToday ? dueToday + 86400000 : dueToday);

    return { messages: out, snapshot: s };
}

// ---------------------------------------------------------------------------

async function main() {
    const args = parseArgs(process.argv);

    if (args.help) {
        console.log('usage: node bots/announce.js [--config FILE] [--once] [--dry-run]');
        return 0;
    }

    const configFile = args.config
        || process.env.WAM_ANNOUNCE_CONFIG
        || '/etc/wam/announce.json';

    const cfg = loadConfig(configFile);
    const stamp = () => new Date().toISOString().replace('T', ' ').slice(0, 19);
    const log = (m) => console.log(`${stamp()}  ${m}`);

    const rpc = new NodeRpc(cfg.node);
    const sinks = buildSinks(cfg);
    const state = loadState(cfg.stateFile);

    log(`WAM announcement bot`);
    log(`node      ${cfg.node.host}:${cfg.node.port}`);
    log(`channels  ${sinks.map((s) => s.name).join(', ')}`);
    log(`daily post at ${String(cfg.heartbeatHourUtc).padStart(2, '0')}:00 UTC, stall alert after ${cfg.stallMinutes}m`);
    if (args.dry) log(`DRY RUN -- messages are printed, not sent`);

    const runOnce = async () => {
        let result;
        try {
            result = await tick(cfg, rpc, state, log);
        } catch (err) {
            log(`could not read the node: ${err.message}`);
            return;
        }

        // Every event message carries the chain banner, not just the
        // heartbeat. A halving announcement is the message most likely to be
        // screenshotted and forwarded, and it is the one where "which chain?"
        // matters most. The heartbeat adds its own, so it is skipped here.
        {
            const banner = networkLabel(result.snapshot.chainName);
            if (banner) {
                result.messages = result.messages.map(
                    (m) => (m.includes(banner) ? m : `${banner}\n\n${m}`));
            }
        }

        // A dry run must not touch the state file. It did once, and the effect
        // was exactly the wrong shape: the operator tested the bot, saw the
        // message it *would* send, and then the real run announced nothing --
        // because the test had already marked it as announced.
        //
        // A rehearsal that changes the thing it is rehearsing is not a
        // rehearsal.
        if (args.dry) {
            for (const message of result.messages) {
                for (const [service, render] of [['telegram', toTelegram], ['discord', toDiscord]]) {
                    console.log(`\n---8<--- ${service}\n` + render(message) + '\n--->8---');
                }
            }
            if (result.messages.length === 0) {
                log(`height ${result.snapshot.height}, nothing to announce`);
            }
            log('dry run: the state file was not written');
            return;
        }

        for (const message of result.messages) {
            const label = toPlain(message).split('\n')[0];
            // Each channel independently. One service being down, rate limited
            // or misconfigured must not cost the announcement on the other --
            // and must not stop the loop, since the next message may be the
            // stall alert that says the chain has stopped.
            for (const sink of sinks) {
                try {
                    await sink.send(message);
                    log(`sent to ${sink.name} (${label})`);
                } catch (err) {
                    log(`${sink.name} send failed: ${err.message}`);
                }
            }
        }

        saveState(cfg.stateFile, state);
        if (result.messages.length === 0) {
            log(`height ${result.snapshot.height}, nothing to announce`);
        }
    };

    await runOnce();
    if (args.once) return 0;

    setInterval(runOnce, cfg.pollSeconds * 1000);

    const shutdown = (sig) => {
        log(`${sig} received, saving state`);
        saveState(cfg.stateFile, state);
        process.exit(0);
    };
    process.on('SIGINT', () => shutdown('SIGINT'));
    process.on('SIGTERM', () => shutdown('SIGTERM'));

    return new Promise(() => {});
}

module.exports = {
    heartbeat, halvingMessage, rotationMessage, releaseMessage,
    milestoneMessage, stallMessage, recoveredMessage, networkLabel,
    loadConfig, tick, num, wam, hashrate, duration
};

if (require.main === module) {
    main().then((code) => {
        if (typeof code === 'number' && code !== 0) process.exit(code);
    }).catch((err) => {
        console.error(err.stack || err.message);
        process.exit(1);
    });
}

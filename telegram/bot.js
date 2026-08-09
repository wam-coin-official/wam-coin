#!/usr/bin/env node
'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  The WAM announcement bot
// ===========================================================================
//
//      node telegram/bot.js [--config telegram/config.json] [--once] [--dry-run]
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

const fs = require('fs');
const path = require('path');

const { NodeRpc, Telegram, latestRelease } = require('./lib/clients');

const COIN = 100000000;

// ---------------------------------------------------------------------------

function parseArgs(argv) {
    const out = { config: path.join(__dirname, 'config.json'), once: false, dry: false };
    for (let i = 2; i < argv.length; i++) {
        if (argv[i] === '--config' && argv[i + 1]) out.config = argv[++i];
        else if (argv[i] === '--once') out.once = true;
        else if (argv[i] === '--dry-run') out.dry = true;
        else if (argv[i] === '--help' || argv[i] === '-h') out.help = true;
    }
    return out;
}

function loadConfig(file) {
    if (!fs.existsSync(file)) {
        throw new Error(`config not found: ${file}\nCopy config.example.json and edit it.`);
    }
    const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));

    for (const key of ['telegram', 'node']) {
        if (!cfg[key]) throw new Error(`config is missing '${key}'`);
    }
    if (!cfg.telegram.token || cfg.telegram.token.includes('CHANGE_ME')) {
        throw new Error('refusing to start with a placeholder bot token');
    }
    if (!cfg.telegram.chatId) throw new Error('config.telegram.chatId is required');

    // ?? not ||, so that a deliberate 0 survives. With || a configured
    // heartbeatHours of 0 silently becomes 24, and the operator is left
    // wondering why the setting does nothing.
    cfg.pollSeconds       = cfg.pollSeconds       ?? 60;
    cfg.heartbeatHours    = cfg.heartbeatHours    ?? 24;
    cfg.stallMinutes      = cfg.stallMinutes      ?? 60;
    cfg.githubRepo        = cfg.githubRepo        ?? null;
    cfg.stateFile         = cfg.stateFile         ?? path.join(__dirname, 'state.json');
    cfg.milestoneHeights  = cfg.milestoneHeights  ?? [1, 100, 1000, 10000, 50000,
                                                      100000, 200000, 400000, 500000,
                                                      1000000, 2000000, 5000000, 6600000];
    return cfg;
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
// ---------------------------------------------------------------------------

function heartbeat(s, cfg) {
    const sup = s.supply || {};
    const lines = [
        `🟢 <b>WAM Network</b>`,
        ``,
        `<b>Height</b>        ${num(s.height)}`,
        `<b>Hashrate</b>      ${hashrate(s.hashrate)}`
    ];

    if (sup.block_subsidy !== undefined) {
        const subsidy = Math.round(Number(sup.block_subsidy) * COIN);
        const treasury = Math.round(Number(sup.treasury_subsidy || 0) * COIN);
        lines.push(`<b>Block reward</b>  ${wam(subsidy)} WAM` +
                   (treasury > 0 ? `  (${wam(subsidy - treasury)} miner + ${wam(treasury)} treasury)` : ''));
    }

    if (sup.circulating !== undefined && sup.max_supply !== undefined) {
        const pct = (Number(sup.circulating) / Number(sup.max_supply) * 100).toFixed(2);
        lines.push(`<b>Supply</b>        ${num(Math.round(Number(sup.circulating)))} / ` +
                   `${num(Math.round(Number(sup.max_supply)))}  (${pct}%)`);
    }

    // Do not promise a halving that can no longer happen. Once the subsidy has
    // decayed to zero the node still reports a next_halving_height, but there
    // is nothing left to halve.
    const subsidySat = sup.block_subsidy !== undefined
        ? Math.round(Number(sup.block_subsidy) * COIN) : null;

    if (subsidySat === 0) {
        lines.push(`<b>Emission</b>      complete — miners are paid by fees alone`);
    } else if (sup.blocks_until_halving > 0) {
        lines.push(`<b>Next halving</b>  in ${num(sup.blocks_until_halving)} blocks ` +
                   `(${duration(sup.blocks_until_halving * 120)})`);
    }

    const rx = s.randomx;
    if (rx && rx.blocks_until_rotation > 0) {
        lines.push(`<b>RandomX key</b>   rotates in ${num(rx.blocks_until_rotation)} blocks`);
    }

    if (cfg.explorerUrl) lines.push(``, cfg.explorerUrl);
    return lines.join('\n');
}

function halvingMessage(before, after, height) {
    return [
        `⛏ <b>The block reward has halved</b>`,
        ``,
        `At height ${num(height)} the subsidy went from`,
        `<b>${wam(before)} WAM</b> to <b>${wam(after)} WAM</b>.`,
        ``,
        `This is written into consensus and happens every 200,000 blocks.`,
        `No decision was taken and none could be.`
    ].join('\n');
}

function rotationMessage(seedHeight, height) {
    return [
        `🔑 <b>RandomX key rotated</b>`,
        ``,
        `From height ${num(height)} the proof-of-work key is derived from`,
        `block ${num(seedHeight)}.`,
        ``,
        `Every miner rebuilds its dataset now; a brief dip in network`,
        `hashrate over the next few minutes is expected, not a fault.`
    ].join('\n');
}

function releaseMessage(release) {
    const body = Telegram.escape(String(release.body || '').split('\n').slice(0, 8).join('\n')).slice(0, 700);
    return [
        `🚀 <b>${Telegram.escape(release.name || release.tag)}</b>`,
        ``,
        body,
        ``,
        release.url,
        ``,
        `<i>Verify the checksums before you run it.</i>`
    ].filter((l) => l !== undefined).join('\n');
}

function milestoneMessage(kind, value) {
    if (kind === 'height') {
        return `📍 <b>Block ${num(value)}</b>\n\nThe chain has reached height ${num(value)}.`;
    }
    return `📍 <b>${num(value)} WAM mined</b>\n\nOut of a hard cap of 22,000,000.`;
}

function stallMessage(minutes, height) {
    return [
        `🔴 <b>No new block for ${minutes} minutes</b>`,
        ``,
        `The chain is still at height ${num(height)}. The target is one block`,
        `every two minutes.`,
        ``,
        `This usually means the network hashrate has dropped. It is posted`,
        `here because a channel that only reports good news is advertising.`
    ].join('\n');
}

function recoveredMessage(height, minutes) {
    return `🟢 <b>Blocks are arriving again</b>\n\nHeight ${num(height)}, after ${minutes} minutes.`;
}

// ---------------------------------------------------------------------------
// One pass
// ---------------------------------------------------------------------------

async function tick(cfg, rpc, tg, state, log) {
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
    const sinceBeat = now - (state.lastHeartbeatAt || 0);
    if (sinceBeat >= cfg.heartbeatHours * 3600 * 1000) {
        out.push(heartbeat(s, cfg));
        state.lastHeartbeatAt = now;
    }

    return { messages: out, snapshot: s };
}

// ---------------------------------------------------------------------------

async function main() {
    const args = parseArgs(process.argv);

    if (args.help) {
        console.log('usage: node telegram/bot.js [--config FILE] [--once] [--dry-run]');
        return 0;
    }

    const cfg = loadConfig(args.config);
    const stamp = () => new Date().toISOString().replace('T', ' ').slice(0, 19);
    const log = (m) => console.log(`${stamp()}  ${m}`);

    const rpc = new NodeRpc(cfg.node);
    const tg = new Telegram(cfg.telegram);
    const state = loadState(cfg.stateFile);

    log(`WAM announcement bot`);
    log(`node      ${cfg.node.host}:${cfg.node.port}`);
    log(`channel   ${cfg.telegram.chatId}`);
    log(`heartbeat every ${cfg.heartbeatHours}h, stall alert after ${cfg.stallMinutes}m`);
    if (args.dry) log(`DRY RUN -- messages are printed, not sent`);

    const runOnce = async () => {
        let result;
        try {
            result = await tick(cfg, rpc, tg, state, log);
        } catch (err) {
            log(`could not read the node: ${err.message}`);
            return;
        }

        // A dry run must not touch the state file. It did once, and the effect
        // was exactly the wrong shape: the operator tested the bot, saw the
        // message it *would* send, and then the real run announced nothing --
        // because the test had already marked it as announced.
        //
        // A rehearsal that changes the thing it is rehearsing is not a
        // rehearsal.
        if (args.dry) {
            for (const text of result.messages) {
                console.log('\n---8<---\n' + text + '\n--->8---\n');
            }
            if (result.messages.length === 0) {
                log(`height ${result.snapshot.height}, nothing to announce`);
            }
            log('dry run: the state file was not written');
            return;
        }

        for (const text of result.messages) {
            try {
                await tg.send(text);
                log(`sent (${text.split('\n')[0].replace(/<[^>]+>/g, '')})`);
            } catch (err) {
                // Do not lose the state update because Telegram was briefly
                // unreachable -- but do not mark the message as sent either.
                log(`send failed: ${err.message}`);
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

main().then((code) => {
    if (typeof code === 'number' && code !== 0) process.exit(code);
}).catch((err) => {
    console.error(err.stack || err.message);
    process.exit(1);
});

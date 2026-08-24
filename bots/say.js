'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  say.js -- post one written message to the announcement channels
// ===========================================================================
//
//      node bots/say.js --file note.txt --dry-run
//      node bots/say.js --file note.txt
//
//  WHY THIS EXISTS
//
//  announce.js posts what it can compute: a new release, a halving, a
//  milestone, a chain that stalled. Its release message is deliberately
//  uniform -- title, build provenance, checksum command, link -- because it
//  is written before anyone knows what the release will contain.
//
//  v0.1.6 showed the limit of that. The automatic post said "WAM Coin
//  v0.1.6" and gave a checksum command, which is true and tells a miner
//  nothing. The thing that mattered -- that a miner could sit on a dead
//  connection for six hours and lose everything it would have earned, and
//  that the fix is this download -- was in the release notes and nowhere a
//  reader would meet it.
//
//  So there is a way to say something in words, through the same sinks, with
//  the same credential handling, the same escaping and the same length
//  limits. The alternative is pasting into Telegram by hand, which is how a
//  message goes out to one channel and not the other.
//
//  MARKUP
//
//  Deliberately small, because it renders to two services with different
//  escaping rules and every construct is a way to get that wrong:
//
//      *bold*        _italic_        `inline`
//      ```           a fenced block, sent as preformatted text
//      ```
//
//  A line that is only a URL is sent as a bare link, which is what both
//  services want in order to render a preview.
// ===========================================================================

const fs = require('fs');
const path = require('path');

const { loadConfig } = require('./lib/config');
const { buildSinks } = require('./lib/sinks');
const { b, i, t, code, kbd, toTelegram, toDiscord, toPlain } = require('./lib/markup');
const { NodeRpc } = require('./lib/clients');
const { networkLabel } = require('./announce');

function parseArgs(argv) {
    const out = { config: null, file: null, dry: false };
    for (let n = 2; n < argv.length; n++) {
        if (argv[n] === '--config' && argv[n + 1]) out.config = argv[++n];
        else if (argv[n] === '--file' && argv[n + 1]) out.file = argv[++n];
        else if (argv[n] === '--dry-run') out.dry = true;
        else if (argv[n] === '--help' || argv[n] === '-h') out.help = true;
        else { out.bad = argv[n]; }
    }
    return out;
}

/** Turn one line of the source file into a marked-up line. */
function inline(line) {
    // Inline code first, so nothing inside it is reinterpreted.
    const spans = [];
    let s = line.replace(/`([^`]+)`/g, (_, x) => {
        spans.push(kbd(x));
        return `${spans.length - 1}`;
    });
    s = s.replace(/\*([^*]+)\*/g, (_, x) => b(x));
    s = s.replace(/(?<![\w_])_([^_\n]+)_(?![\w_])/g, (_, x) => i(x));
    return s.replace(/(\d+)/g, (_, n) => spans[Number(n)]);
}

function render(text) {
    const out = [];
    const lines = text.replace(/\r\n/g, '\n').split('\n');
    for (let n = 0; n < lines.length; n++) {
        if (lines[n].startsWith('```')) {
            const buf = [];
            n++;
            while (n < lines.length && !lines[n].startsWith('```')) buf.push(lines[n++]);
            out.push(code(buf.join('\n')));
            continue;
        }
        if (/^https?:\/\/\S+$/.test(lines[n].trim())) {
            out.push(t(lines[n].trim()));
            continue;
        }
        out.push(inline(lines[n]));
    }
    // Trailing blank lines add nothing and Telegram keeps them.
    while (out.length && String(out[out.length - 1]).trim() === '') out.pop();

    // Joined, not returned as an array. Every message in announce.js is a
    // string -- toPlain() is String(message).replace(...), so handing the
    // sinks an array would have produced a comma-separated message, and the
    // label in the send log would have been the entire text on one line.
    return out.join('\n');
}

async function main() {
    const args = parseArgs(process.argv);
    if (args.help || !args.file) {
        console.log('usage: node bots/say.js --file FILE [--config FILE] [--dry-run]');
        return args.help ? 0 : 2;
    }
    if (args.bad) {
        console.error(`unknown argument: ${args.bad}`);
        return 2;
    }
    if (!fs.existsSync(args.file)) {
        console.error(`no such file: ${args.file}`);
        return 2;
    }

    const configFile = args.config || process.env.WAM_ANNOUNCE_CONFIG ||
        path.join(__dirname, 'announce.json');
    const cfg = loadConfig(configFile);

    let message = render(fs.readFileSync(args.file, 'utf8'));
    if (message.trim().length === 0) {
        console.error('the message is empty');
        return 2;
    }

    // Which chain this came from, in the same words announce.js uses. A
    // message about testnet that does not say testnet is the one thing these
    // channels must never send.
    try {
        const rpc = new NodeRpc(cfg.node);
        const info = await rpc.call('getblockchaininfo');
        const banner = networkLabel(info.chain);
        if (banner) message = `${banner}\n\n${message}`;
    } catch (err) {
        console.error(`could not ask the node which chain it is on: ${err.message}`);
        console.error('refusing to post an unlabelled message');
        return 1;
    }

    if (args.dry) {
        for (const [service, renderAs] of [['telegram', toTelegram], ['discord', toDiscord]]) {
            console.log(`\n---8<--- ${service}`);
            console.log(renderAs(message));
            console.log('--->8---');
        }
        console.log('\ndry run: nothing was sent');
        return 0;
    }

    const sinks = buildSinks(cfg);
    const label = toPlain(message).split('\n').filter((x) => x.trim())[0] || '';
    let failed = 0;
    // Each channel independently: one being down must not cost the other.
    for (const sink of sinks) {
        try {
            await sink.send(message);
            console.log(`sent to ${sink.name} (${label.slice(0, 60)})`);
        } catch (err) {
            console.error(`${sink.name} send failed: ${err.message}`);
            failed++;
        }
    }
    return failed === 0 ? 0 : 1;
}

if (require.main === module) {
    main().then((c) => { if (c) process.exit(c); })
        .catch((err) => { console.error(err.stack || err.message); process.exit(1); });
}

module.exports = { render, inline };

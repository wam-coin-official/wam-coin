'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// The sinks hold the credentials and decide what leaves the machine, so the
// tests here are about the two ways that goes wrong quietly.
//
// A credential in a log. The Telegram token is in the request path and a
// Discord webhook is a URL with its token inside it. An error that quotes the
// URL -- from https, from DNS, from a well-meant edit -- publishes the key to
// the announcement channel into a file, and journald keeps it.
//
// A message that mentions people. Release titles and notes are written by
// other people. "@everyone" in one of them, sent by a bot nobody can reply to,
// notifies an entire server.
//
// Neither failure is visible in normal operation, which is why they are held
// here rather than noticed later.
// ---------------------------------------------------------------------------

const assert = require('assert');
const { TelegramSink, DiscordSink, buildSinks, scrub, fit } = require('../lib/sinks');
const { b, t } = require('../lib/markup');

let pass = 0;
const fail = [];

function test(name, fn) {
    try { fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

const HOOK = 'https://discord.com/api/webhooks/123456789/AbCdEf-ghijkl_MNOPQ';
const TOKEN = '1234567890:AAH0abcdefghijklmnopqrstuvwxyz012345';

console.log('\n=== a credential never reaches a log ===');

test('a Discord webhook is redacted out of any text', () => {
    const out = scrub(`connect ECONNREFUSED while posting to ${HOOK}`);
    assert.ok(!out.includes('AbCdEf-ghijkl_MNOPQ'), `the webhook token survived: ${out}`);
    assert.ok(out.includes('<redacted>'));
});

test('a Telegram token is redacted out of any text', () => {
    assert.ok(!scrub(`POST /bot${TOKEN}/sendMessage failed`).includes(TOKEN));
    assert.ok(!scrub(`token was ${TOKEN}`).includes(TOKEN));
});

test('ordinary text is left alone', () => {
    const msg = 'the node at 127.0.0.1:19555 did not answer';
    assert.strictEqual(scrub(msg), msg);
});

console.log('\n=== Discord will not post anywhere but Discord ===');

test('a non-Discord host is refused', () => {
    for (const bad of ['https://evil.example/api/webhooks/1/x',
                       'http://discord.com/api/webhooks/1/x',
                       'https://discord.com/api/channels/1/messages',
                       'https://notdiscord.com/api/webhooks/1/x']) {
        assert.throws(() => new DiscordSink({ webhookUrl: bad }), /not a Discord webhook|not a URL/,
            `accepted ${bad}`);
    }
});

test('the real webhook hosts are accepted', () => {
    for (const good of [HOOK,
                        HOOK.replace('discord.com', 'discordapp.com'),
                        HOOK.replace('discord.com', 'canary.discord.com')]) {
        assert.doesNotThrow(() => new DiscordSink({ webhookUrl: good }), `rejected ${good}`);
    }
});

test('a missing webhook fails at construction, not at the first announcement', () => {
    assert.throws(() => new DiscordSink({}), /no webhookUrl/);
    assert.throws(() => new TelegramSink({ token: TOKEN }), /no chatId/);
    assert.throws(() => new TelegramSink({ chatId: '-100' }), /no token/);
});

console.log('\n=== a message cannot mention anyone ===');

test('mentions are denied in the request, not filtered in the text', () => {
    // Capture the body the sink would send.
    const sink = new DiscordSink({ webhookUrl: HOOK });
    let sent = null;
    const https = require('https');
    const original = https.request;
    https.request = (opts, cb) => {
        return {
            on() { return this; },
            write(payload) { sent = JSON.parse(payload); },
            end() { cb({ statusCode: 204, headers: {}, on(ev, fn) { if (ev === 'end') fn(); return this; } }); }
        };
    };
    try {
        sink.send(`${b('Release')}: ${t('@everyone please update')}`);
    } finally {
        https.request = original;
    }

    assert.ok(sent, 'nothing was sent');
    assert.deepStrictEqual(sent.allowed_mentions, { parse: [] },
        'allowed_mentions does not deny every mention type; @everyone in a '
        + 'release note would ping the whole server');
    assert.ok(sent.content.includes('@everyone'),
        'the text was altered instead of the mention being denied at the API');
});

console.log('\n=== long messages are cut, not rejected ===');

test('Discord messages are cut to its limit', () => {
    const long = 'x'.repeat(5000);
    const out = fit(long, 2000);
    assert.ok(out.length <= 2000, `still ${out.length} characters`);
    assert.ok(out.endsWith('...'), 'a cut message does not say it was cut');
});

test('a message that fits is untouched', () => {
    assert.strictEqual(fit('short', 2000), 'short');
});

test('cutting prefers a line boundary', () => {
    const text = 'a'.repeat(1900) + '\n' + 'b'.repeat(300);
    const out = fit(text, 2000);
    assert.ok(!out.includes('b'), 'the cut landed mid-line instead of at the newline');
});

console.log('\n=== a configuration builds the sinks it names ===');

test('both, one, or neither', () => {
    assert.strictEqual(buildSinks({}).length, 0);
    assert.strictEqual(buildSinks({ discord: { webhookUrl: HOOK } }).length, 1);
    assert.strictEqual(buildSinks({ telegram: { token: TOKEN, chatId: '-100' } }).length, 1);
    assert.strictEqual(buildSinks({
        telegram: { token: TOKEN, chatId: '-100' },
        discord: { webhookUrl: HOOK }
    }).length, 2);
});

test('a configured but broken sink throws at start-up', () => {
    assert.throws(() => buildSinks({ discord: { webhookUrl: 'https://evil.example/x' } }),
        /not a Discord webhook/,
        'a bad webhook would have been discovered at the first announcement instead');
});

test('each sink knows its own name, for logs', () => {
    assert.strictEqual(new DiscordSink({ webhookUrl: HOOK }).name, 'discord');
    assert.strictEqual(new TelegramSink({ token: TOKEN, chatId: '-1' }).name, 'telegram');
});

console.log('\n' + '='.repeat(66));
if (fail.length === 0) {
    console.log(`\x1b[32m${pass} passed\x1b[0m`);
} else {
    console.log(`\x1b[31m${fail.length} failed\x1b[0m, ${pass} passed`);
    fail.forEach((f) => console.log(`  - ${f}`));
}
console.log('='.repeat(66));
process.exit(fail.length === 0 ? 0 : 1);

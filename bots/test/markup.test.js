'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// Everything the announcement bot says passes through here, so a fault in this
// file is a fault in every message on every service.
//
// Two properties matter and they pull against each other. A message must come
// out formatted -- bold where bold was meant -- and it must come out inert: a
// release title from GitHub cannot be allowed to close a tag, open a code
// block, or forge a mark of its own. The old design got the first by hand and
// the second by remembering; these tests hold both without either.
// ---------------------------------------------------------------------------

const assert = require('assert');
const M = require('../lib/markup');

let pass = 0;
const fail = [];

function test(name, fn) {
    try { fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

console.log('\n=== formatting reaches each service in its own dialect ===');

test('bold', () => {
    const m = `Height ${M.b('1234')}`;
    assert.strictEqual(M.toTelegram(m), 'Height <b>1234</b>');
    assert.strictEqual(M.toDiscord(m), 'Height **1234**');
    assert.strictEqual(M.toPlain(m), 'Height 1234');
});

test('italic', () => {
    const m = M.i('verify the checksums');
    assert.strictEqual(M.toTelegram(m), '<i>verify the checksums</i>');
    assert.strictEqual(M.toDiscord(m), '*verify the checksums*');
});

test('nothing is left holding a mark', () => {
    const rendered = [M.toTelegram, M.toDiscord, M.toPlain]
        .map((f) => f(`${M.b('a')} ${M.i('b')}`));
    for (const r of rendered) {
        assert.ok(!/[\u0011-\u0014]/.test(r), `a mark survived rendering: ${JSON.stringify(r)}`);
    }
});

test('newlines and emoji are untouched', () => {
    const m = `\u{1F7E2} ${M.b('WAM')}\n\nsecond line`;
    assert.strictEqual(M.toTelegram(m), '\u{1F7E2} <b>WAM</b>\n\nsecond line');
    assert.ok(M.toDiscord(m).includes('\n\nsecond line'));
});

console.log('\n=== text from outside cannot change how a message renders ===');

test('Telegram HTML is escaped, not obeyed', () => {
    const out = M.toTelegram(`title: ${M.t('<b>fake</b> & <script>')}`);
    assert.ok(!out.includes('<b>fake'), `raw HTML survived: ${out}`);
    assert.strictEqual(out, 'title: &lt;b&gt;fake&lt;/b&gt; &amp; &lt;script&gt;');
});

test('Discord markdown is escaped, not obeyed', () => {
    const out = M.toDiscord(M.t('**bold** and `code` and ~~strike~~'));
    assert.ok(!/(?<!\\)\*\*bold/.test(out), `unescaped markdown survived: ${out}`);
    assert.ok(out.includes('\\`code\\`'), `backticks were not escaped: ${out}`);
});

test('a release title cannot forge a mark', () => {
    // The attack the marks invite: a title containing the bold character,
    // hoping the renderer treats it as our formatting.
    const hostile = `v1.0 \u0011everything after this bold\u0012`;
    const out = M.toTelegram(`${M.b('Release')}: ${M.t(hostile)}`);
    assert.strictEqual(out, '<b>Release</b>: v1.0 everything after this bold',
        'a forged mark was honoured as formatting');
});

test('b() and i() strip forged marks from their own content too', () => {
    const out = M.toTelegram(M.b(`title\u0012 escaped \u0011more`));
    assert.strictEqual(out, '<b>title escaped more</b>');
});

test('control characters are removed but newlines survive', () => {
    assert.strictEqual(M.clean('a\u0000b\u0007c'), 'abc');
    assert.strictEqual(M.clean('line1\nline2\tx'), 'line1\nline2\tx');
    assert.strictEqual(M.clean('a\u007Fb'), 'ab');
});

test('null and undefined become empty, not the words', () => {
    assert.strictEqual(M.clean(undefined), '');
    assert.strictEqual(M.clean(null), '');
    assert.strictEqual(M.toTelegram(M.b(undefined)), '<b></b>');
});

console.log('\n=== the two renderers agree about structure ===');

test('same marks, same number of bold runs', () => {
    const m = `${M.b('A')} x ${M.b('B')} y ${M.i('C')}`;
    assert.strictEqual((M.toTelegram(m).match(/<b>/g) || []).length, 2);
    assert.strictEqual((M.toDiscord(m).match(/\*\*/g) || []).length, 4);   // open+close
});

test('a message with no marks is only escaped', () => {
    assert.strictEqual(M.toTelegram('plain & simple'), 'plain &amp; simple');
    assert.strictEqual(M.toDiscord('plain & simple'), 'plain & simple');
    assert.strictEqual(M.toPlain('plain & simple'), 'plain & simple');
});

test('an empty message stays empty everywhere', () => {
    for (const f of [M.toTelegram, M.toDiscord, M.toPlain]) {
        assert.strictEqual(f(''), '');
    }
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

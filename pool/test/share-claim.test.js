'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// The duplicate-share set had to do two incompatible-looking jobs at once.
//
// It has to be authoritative: a share that was credited must never be credited
// again, and the check that decides this cannot yield between looking and
// claiming, because a client's messages are not processed one at a time and
// two copies of one share can be in flight together.
//
// And it has to be bounded: it used to record every syntactically valid
// submission, including ones that fail the difficulty check and therefore cost
// the sender nothing. At the message rate limit that is thousands of permanent
// entries a second from a single address -- the pool dies of memory without
// anyone having mined.
//
// Capping the set would have satisfied the second at the cost of the first:
// evict an entry and a real share can be paid twice. Instead the claim is taken
// atomically up front and given back if the share is not credited, so the set
// holds only what was paid for. Filling it now costs an attacker exactly what
// it costs a miner.
//
// These tests hold both properties down at once, because a future change that
// fixes either one alone is the bug coming back.
// ---------------------------------------------------------------------------

const assert = require('assert');
const BlockTemplate = require('../lib/blockTemplate');

let pass = 0;
const fail = [];

async function test(name, fn) {
    try { await fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

/** The claim bookkeeping only, without building a whole template. */
function claimSet() {
    return Object.create(BlockTemplate.prototype, {
        submits: { value: new Set(), writable: true }
    });
}

(async () => {
    console.log('\n=== a claim is authoritative ===');

    await test('the same tuple cannot be claimed twice', () => {
        const j = claimSet();
        assert.strictEqual(j.registerSubmit('aa', 'bb', '01', '02'), true);
        assert.strictEqual(j.registerSubmit('aa', 'bb', '01', '02'), false,
            'a second claim on a held tuple succeeded; the share can be credited twice');
    });

    await test('claiming does not yield, so two in flight cannot both win', () => {
        // The guarantee is structural: registerSubmit must be synchronous. If it
        // ever becomes async, `has` and `add` straddle a yield and both copies
        // of a share pass. Assert the shape, not just the behaviour.
        const j = claimSet();
        const r = j.registerSubmit('aa', 'bb', '01', '02');
        assert.strictEqual(typeof r, 'boolean',
            'registerSubmit no longer returns synchronously; the check-and-claim '
            + 'is no longer atomic and duplicate shares can both be credited');
        assert.notStrictEqual(Object.prototype.toString.call(r), '[object Promise]');
    });

    await test('distinct tuples are distinct claims', () => {
        const j = claimSet();
        assert.ok(j.registerSubmit('aa', 'bb', '01', '02'));
        assert.ok(j.registerSubmit('aa', 'bb', '01', '03'), 'a different nonce was refused');
        assert.ok(j.registerSubmit('aa', 'bc', '01', '02'), 'a different extranonce2 was refused');
        assert.ok(j.registerSubmit('ab', 'bb', '01', '02'), 'a different extranonce1 was refused');
        assert.ok(j.registerSubmit('aa', 'bb', '09', '02'), 'a different ntime was refused');
        assert.strictEqual(j.submits.size, 5);
    });

    console.log('\n=== a claim that was not credited is given back ===');

    await test('releasing frees the tuple', () => {
        const j = claimSet();
        j.registerSubmit('aa', 'bb', '01', '02');
        j.releaseSubmit('aa', 'bb', '01', '02');
        assert.strictEqual(j.submits.size, 0, 'the entry survived its release');
        assert.strictEqual(j.registerSubmit('aa', 'bb', '01', '02'), true,
            'a released tuple could not be claimed again');
    });

    await test('releasing an unheld tuple is harmless', () => {
        const j = claimSet();
        j.releaseSubmit('zz', 'zz', '00', '00');
        assert.strictEqual(j.submits.size, 0);
    });

    await test('releasing one claim does not disturb another', () => {
        const j = claimSet();
        j.registerSubmit('aa', 'bb', '01', '02');
        j.registerSubmit('aa', 'bb', '01', '03');
        j.releaseSubmit('aa', 'bb', '01', '02');
        assert.strictEqual(j.submits.size, 1);
        assert.strictEqual(j.registerSubmit('aa', 'bb', '01', '03'), false,
            'the surviving claim was dropped along with the released one');
    });

    await test('a flood of rejected shares leaves nothing behind', () => {
        // What the attack looked like: submit valid-looking tuples as fast as
        // the rate limit allows, none of which meet the difficulty. Every one
        // used to be a permanent entry.
        const j = claimSet();
        for (let i = 0; i < 200000; i++) {
            const nonce = i.toString(16).padStart(8, '0');
            assert.ok(j.registerSubmit('aa', 'bb', '01', nonce));
            j.releaseSubmit('aa', 'bb', '01', nonce);          // rejected
        }
        assert.strictEqual(j.submits.size, 0,
            `200,000 rejected shares left ${j.submits.size} entries; this is the `
            + 'memory exhaustion path reopening');
    });

    await test('credited shares are still remembered through the same flood', () => {
        const j = claimSet();
        j.registerSubmit('aa', 'bb', '01', 'deadbeef');         // credited, kept
        for (let i = 0; i < 50000; i++) {
            const nonce = i.toString(16).padStart(8, '0');
            j.registerSubmit('aa', 'bb', '01', nonce);
            j.releaseSubmit('aa', 'bb', '01', nonce);
        }
        assert.strictEqual(j.submits.size, 1, 'the credited share was swept away with the junk');
        assert.strictEqual(j.registerSubmit('aa', 'bb', '01', 'deadbeef'), false,
            'the credited share could be submitted and paid a second time');
    });

    console.log('\n=== the release is wired into every rejection path ===');

    await test('processShare releases on rejection and keeps on credit', () => {
        // Rather than mock RandomX, assert the structure that makes it true for
        // paths that do not exist yet: one `finally` covering the whole tail,
        // and the flag set only after the share is known to count.
        const src = require('fs').readFileSync(require.resolve('../lib/jobManager'), 'utf8');
        const body = src.slice(src.indexOf('async processShare'));
        const tail = body.slice(0, body.indexOf('\n    async _submitBlock'));

        assert.ok(/}\s*finally\s*\{[^}]*releaseSubmit/.test(tail),
            'the release is not in a finally block; a rejection path added later '
            + 'will leak claims again');
        assert.ok(/credited\s*=\s*true;[\s\S]{0,200}return \{ valid: true/.test(tail),
            'the credited flag is not set immediately before the success return');

        const claimAt = tail.indexOf('registerSubmit');
        const tryAt = tail.indexOf('try {', claimAt);
        const hashAt = tail.indexOf('randomx.hash');
        assert.ok(claimAt > -1 && tryAt > claimAt && hashAt > tryAt,
            'the claim must be taken before the try, and hashing must happen '
            + 'inside it: claiming after the hash reopens the race');
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
})();

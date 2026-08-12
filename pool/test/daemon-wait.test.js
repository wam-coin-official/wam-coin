'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// The pool must wait for a booting node, and must still refuse a missing one.
//
// A node takes a minute or two to load its block index and wallets, answering
// ECONNREFUSED and then RPC_IN_WARMUP (-28) the whole way. The pool used to
// exit on the first refusal; systemd restarted it; the two raced. With
// StartLimitBurst=5 the race can end with systemd giving up for good, so the
// pool stays down after every reboot until a human runs reset-failed.
//
// Both halves matter. Waiting forever for a node that will never exist is just
// a different outage, and a quieter one.
// ---------------------------------------------------------------------------

const assert = require('assert');
const Daemon = require('../lib/daemon');

let pass = 0;
const fail = [];
const quiet = { info() {}, warn() {}, error() {}, debug() {} };

async function test(name, fn) {
    try { await fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

/** A daemon whose _request fails until `succeedAfter` calls have been made. */
function fakeDaemon(succeedAfter, error = new Error('connect ECONNREFUSED')) {
    const d = new Daemon([{ host: '127.0.0.1', port: 1, user: 'u', password: 'p' }], quiet);
    let calls = 0;
    d._request = async () => {
        if (++calls < succeedAfter) throw error;
        return { chain: 'test', blocks: 42, difficulty: 0.001 };
    };
    d.calls = () => calls;
    return d;
}

(async () => {
    console.log('\n=== waiting for a node that is still booting ===');

    await test('a node available immediately is not waited for', async () => {
        const d = fakeDaemon(1);
        const t0 = Date.now();
        await d.init(30);
        assert.ok(Date.now() - t0 < 1000, 'should not sleep when the node answers');
        assert.strictEqual(d.calls(), 1);
    });

    await test('a node that appears on the third attempt is waited for', async () => {
        const d = fakeDaemon(3);
        await d.init(30);
        assert.strictEqual(d.calls(), 3);
        assert.ok(d.daemons[0].online, 'should be marked online once it answers');
    });

    await test('RPC_IN_WARMUP is treated as "not yet", not as broken', async () => {
        // What a loading node actually returns once its RPC port is open.
        const d = fakeDaemon(2, new Error('Loading wallet... (code -28)'));
        await d.init(30);
        assert.strictEqual(d.calls(), 2);
    });

    console.log('\n=== still refusing a node that will never arrive ===');

    await test('gives up after the deadline rather than hanging', async () => {
        const d = fakeDaemon(Infinity);
        const t0 = Date.now();
        await assert.rejects(() => d.init(4), /refusing to start/);
        const elapsed = (Date.now() - t0) / 1000;
        assert.ok(elapsed >= 3.5, `gave up after only ${elapsed.toFixed(1)}s`);
        assert.ok(elapsed < 12, `took ${elapsed.toFixed(1)}s, far past the deadline`);
    });

    await test('the failure names the wait and the underlying reason', async () => {
        const d = fakeDaemon(Infinity, new Error('401 Unauthorized'));
        await assert.rejects(() => d.init(1), (e) => {
            assert.ok(/401 Unauthorized/.test(e.message), 'must surface the real cause');
            assert.ok(/1s|attempts/.test(e.message), 'must say it waited');
            return true;
        });
    });

    await test('a wrong password does not become a silent hang', async () => {
        // The case the wait must not disguise: credentials that will never work.
        const d = fakeDaemon(Infinity, new Error('401 Unauthorized'));
        const t0 = Date.now();
        await assert.rejects(() => d.init(2));
        assert.ok((Date.now() - t0) / 1000 < 8, 'must still terminate promptly');
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

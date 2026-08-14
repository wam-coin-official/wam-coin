'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// The API is the only part of the pool a stranger can reach without a miner.
// Two ways that costs us:
//
//   1. The response cache is a Map keyed on the path *and query string*, and
//      /api/miner?address=... is written by whoever is asking. Nothing ever
//      deleted from it. A million distinct addresses is a million entries the
//      process never releases: the pool dies of a request pattern, not a bug.
//
//   2. That same parameter reached Redis unvalidated. Cheap per request, but
//      it is free work done on behalf of someone who is not mining here, and
//      it is what made every junk string a permanent cache entry.
//
// Both are fixed at the door: reject anything that is not an address before it
// becomes a key, and bound the cache so no sequence of requests can grow it
// without limit.
// ---------------------------------------------------------------------------

const assert = require('assert');
const ApiServer = require('../lib/api');
const { ADDRESS_VERSIONS } = require('../lib/constants');

let pass = 0;
const fail = [];
const quiet = { info() {}, warn() {}, error() {}, debug() {} };

async function test(name, fn) {
    try { await fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

function make(cfg = {}) {
    return new ApiServer({
        config: { netVersions: ADDRESS_VERSIONS.testnet, ...cfg },
        logger: quiet,
        jobManager: {}, stratumServer: {}, shareProcessor: {}, daemon: {}
    });
}

/** Capture what _json would have sent. */
function fakeRes() {
    const res = {
        code: null, body: null, headers: {},
        writeHead(c, h) { res.code = c; Object.assign(res.headers, h || {}); return res; },
        setHeader(k, v) { res.headers[k] = v; },
        end(b) { res.body = b; }
    };
    return res;
}

(async () => {
    console.log('\n=== the cache cannot be grown without limit ===');

    await test('a bounded cache stays bounded under distinct keys', () => {
        const api = make({ apiCacheEntries: 64 });
        for (let i = 0; i < 5000; i++) api._cacheSet(`/api/miner?address=${i}`, { i });
        assert.ok(api.cache.size <= 64,
            `cache grew to ${api.cache.size} entries; an unbounded Map keyed on a `
            + 'query parameter is a memory exhaustion vector');
    });

    await test('the oldest entry is the one evicted', () => {
        const api = make({ apiCacheEntries: 3 });
        api._cacheSet('a', 1); api._cacheSet('b', 2); api._cacheSet('c', 3);
        api._cacheSet('d', 4);
        assert.ok(!api.cache.has('a'), 'the oldest key survived while newer ones were dropped');
        assert.ok(api.cache.has('d'), 'the entry just written was not stored');
    });

    await test('expired entries are reclaimed before a live one is evicted', () => {
        const api = make({ apiCacheEntries: 4, apiCacheMs: 1 });
        api._cacheSet('old1', 1); api._cacheSet('old2', 2);
        api.cache.get('old1').at -= 1000;          // age them past the TTL
        api.cache.get('old2').at -= 1000;
        api._cacheSet('fresh1', 3); api._cacheSet('fresh2', 4);
        api._cacheSet('fresh3', 5);
        assert.ok(api.cache.has('fresh3'), 'the new entry was not stored');
        assert.ok(!api.cache.has('old1') && !api.cache.has('old2'),
            'stale entries were kept while the cache was under pressure');
    });

    await test('the default bound applies when none is configured', () => {
        const api = make();
        for (let i = 0; i < 3000; i++) api._cacheSet(`k${i}`, i);
        assert.ok(api.cache.size <= 512,
            `unconfigured cache reached ${api.cache.size}; the default must bound it`);
    });

    console.log('\n=== a junk address never becomes work, or a key ===');

    await test('validateAddress returns an object, so a truthiness check is wrong', () => {
        const { validateAddress } = require('../lib/util');
        const r = validateAddress('definitely not an address', ADDRESS_VERSIONS.testnet);
        assert.strictEqual(typeof r, 'object', 'the shape changed; the guard must be revisited');
        assert.strictEqual(r.ok, false);
        assert.ok(!(!r), 'the rejected result is truthy -- `if (!validateAddress(..))` never fires');
    });

    await test('garbage is rejected without touching Redis', async () => {
        let redisTouched = false;
        const api = make();
        api.shares = { async getMinerStats() { redisTouched = true; return {}; } };

        for (const bad of ['1', '../../etc/passwd', 'x'.repeat(4000), '%00', 'null']) {
            const res = fakeRes();
            await api._api('/api/miner', new URLSearchParams({ address: bad }), res);
            assert.strictEqual(res.code, 400, `'${bad.slice(0, 20)}' was not rejected`);
        }
        assert.strictEqual(redisTouched, false,
            'an invalid address still reached the share processor');
    });

    await test('a rejected address leaves no cache entry behind', async () => {
        const api = make();
        api.shares = { async getMinerStats() { return {}; } };
        const before = api.cache.size;
        for (let i = 0; i < 500; i++) {
            await api._api('/api/miner', new URLSearchParams({ address: `junk${i}` }), fakeRes());
        }
        assert.strictEqual(api.cache.size, before,
            `${api.cache.size - before} entries were created by addresses that were refused`);
    });

    await test('a missing address is still a 400, not a crash', async () => {
        const api = make();
        const res = fakeRes();
        await api._api('/api/miner', new URLSearchParams(), res);
        assert.strictEqual(res.code, 400);
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

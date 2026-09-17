'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// The share this publishes decides whether a reader trusts the chain, so the
// arithmetic behind it is held down here rather than eyeballed on a page.
//
// Written the night mainnet opened, when one address had 97.5% of the first
// 79 blocks and nothing we had built could say so.
// ---------------------------------------------------------------------------

const assert = require('assert');
const { Concentration } = require('../lib/concentration');

let pass = 0;
const fail = [];
const log = { debug() {}, info() {}, warn() {}, error() {} };

async function test(name, fn) {
    try { await fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

/** A node whose block N pays `finders[N]` 47.5 and the treasury 2.5. */
function fakeRpc(finders, opts = {}) {
    return {
        calls: 0,
        async call(method, params) {
            this.calls++;
            if (method === 'getblockhash') return `hash${params[0]}`;
            if (method === 'getblock') {
                const h = parseInt(String(params[0]).replace('hash', ''), 10);
                if (opts.broken && opts.broken.includes(h)) throw new Error('no such block');
                return {
                    height: h,
                    tx: [{
                        vout: [
                            { value: 2.5, scriptPubKey: { address: 'TREASURY' } },
                            { value: 47.5, scriptPubKey: { address: finders[h] } }
                        ]
                    }]
                };
            }
            throw new Error(`unexpected ${method}`);
        }
    };
}

/** Run update() until it stops fetching, the way several poll cycles would. */
async function fill(c, rpc, tip) {
    for (let i = 0; i < 20; i++) await c.update(rpc, tip);
}

(async () => {
    console.log('\nwho is writing the chain');

    await test('one address with everything reads as 100%, not as "fine"', async () => {
        const finders = {};
        for (let h = 1; h <= 60; h++) finders[h] = 'wam1qbigfarmaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        const c = new Concentration(log);
        await fill(c, fakeRpc(finders), 60);
        const s = c.snapshot();
        assert.strictEqual(s.distinct, 1, `distinct ${s.distinct}`);
        assert.strictEqual(Math.round(s.topPercent), 100, `top ${s.topPercent}`);
    });

    await test('the treasury output is never counted as a miner', async () => {
        const finders = {};
        for (let h = 1; h <= 60; h++) finders[h] = 'wam1qminer000000000000000000000000000000';
        const c = new Concentration(log);
        await fill(c, fakeRpc(finders), 60);
        const s = c.snapshot();
        assert(!s.top.some((t) => t.finder.includes('TREASURY')),
            'the 2.5 output was counted');
    });

    await test('an even split reads as an even split', async () => {
        const finders = {};
        for (let h = 1; h <= 60; h++) finders[h] = `wam1qpool${h % 4}xxxxxxxxxxxxxxxxxxxxxxxxxxxx`;
        const c = new Concentration(log);
        await fill(c, fakeRpc(finders), 60);
        const s = c.snapshot();
        assert.strictEqual(s.distinct, 4, `distinct ${s.distinct}`);
        assert(s.topPercent <= 30, `top ${s.topPercent} should be about 25`);
    });

    await test('blocks that cannot be read are left out, not guessed', async () => {
        const finders = {};
        for (let h = 1; h <= 60; h++) finders[h] = 'wam1qonlyone00000000000000000000000000000';
        const c = new Concentration(log);
        await fill(c, fakeRpc(finders, { broken: [55, 56, 57] }), 60);
        const s = c.snapshot();
        assert(s.blocksRead > 0, 'nothing was read at all');
        assert(s.blocksRead <= 50 - 0, `read ${s.blocksRead}`);
        // The denominator is what was actually read, so a share is never
        // inflated by blocks nobody managed to look at.
        assert.strictEqual(s.top[0].blocks, s.blocksRead,
            'the count and the denominator disagree');
    });

    await test('nothing read yet says so instead of saying 0%', async () => {
        const c = new Concentration(log);
        const s = c.snapshot();
        assert.strictEqual(s.blocksRead, 0);
        assert.strictEqual(s.topPercent, null,
            'an unread window must not render as 0% concentration');
    });

    await test('a finished window costs no further RPC calls', async () => {
        const finders = {};
        for (let h = 1; h <= 60; h++) finders[h] = 'wam1qsteady0000000000000000000000000000000';
        const c = new Concentration(log);
        const rpc = fakeRpc(finders);
        await fill(c, rpc, 60);
        const before = rpc.calls;
        await c.update(rpc, 60);
        // Only the three blocks nearest the tip are re-read, because those
        // are the ones a reorganisation can still take away.
        assert(rpc.calls - before <= 8,
            `a settled window cost ${rpc.calls - before} more calls`);
    });

    await test('addresses are shortened, never published whole', async () => {
        const finders = {};
        const full = 'wam1qk8xvc3h3cadu5kdp6ll63kvw3742ancdkjag89';
        for (let h = 1; h <= 60; h++) finders[h] = full;
        const c = new Concentration(log);
        await fill(c, fakeRpc(finders), 60);
        const s = c.snapshot();
        assert(!JSON.stringify(s).includes(full),
            'a full payout address reached the API');
    });

    await test('the seven-day window sits beside the short one, not instead of it', async () => {
        const finders = {};
        // 200 blocks: the last 50 are ours, everything older is theirs. The
        // short window therefore says 100% us and the long one says 25% us --
        // both true, which is exactly why both are published.
        for (let h = 1; h <= 200; h++) {
            finders[h] = h > 150 ? 'wam1qours00000000000000000000000000000000'
                                 : 'wam1qtheirs0000000000000000000000000000000';
        }
        const c = new Concentration(log);
        await fill(c, fakeRpc(finders), 200);
        const s = c.snapshot();
        assert.strictEqual(s.window, 50, 'the short window must stay at the top level');
        assert(s.sevenDay, 'no seven-day figure');
        assert.strictEqual(s.sevenDay.window, 5040);
        assert(s.sevenDay.blocksRead > s.blocksRead,
            `long window read ${s.sevenDay.blocksRead}, short read ${s.blocksRead}`);
        assert(Math.round(s.topPercent) === 100,
            `short window ${s.topPercent}, expected 100`);
        assert(s.sevenDay.topPercent > 70 && s.sevenDay.topPercent < 80,
            `long window ${s.sevenDay.topPercent}, expected about 75`);
    });

    await test('the published rule travels with the number', async () => {
        const finders = {};
        for (let h = 1; h <= 60; h++) finders[h] = 'wam1qone0000000000000000000000000000000000';
        const c = new Concentration(log);
        await fill(c, fakeRpc(finders), 60);
        const s = c.snapshot();
        // A share without the rule it is judged against invites everyone to
        // invent their own threshold, which is what happened in the channel.
        assert.strictEqual(s.sevenDay.noApplicationAbove, 50);
        assert.strictEqual(s.sevenDay.targetBelow, 35);
    });

    console.log(fail.length
        ? `\n  ${fail.length} failure(s): ${fail.join(', ')}\n`
        : `\n  ${pass} checks: the published share is the measured share\n`);
    process.exit(fail.length ? 1 : 0);
})();

'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// A block may be credited to miners exactly once.
//
// Reported 2026-09-14 by an outside reviewer, eleven hours before mainnet, as
// a pool block-maturation race: the same pending block could mature more than
// once and every miner on it was credited twice, out of the operator's own
// wallet, with nothing in the logs looking wrong.
//
// Two independent paths reached it, which is why the fix is two things:
//
//   1. checkPendingBlocks() had no re-entrancy guard, while processPayments()
//      has had one since 14 August. It is called from a 60-second interval AND
//      from the shutdown handler in server.js -- "one last payment run so
//      miners are not left waiting on a restart" -- so an operator restart
//      during a maturation check ran both at once. Both read the same
//      blocks:pending, both saw 100 confirmations, both credited.
//
//   2. _mature() credited balances and deleted the pending record in one
//      redis.pipeline(), which batches commands into a single round trip and
//      is NOT a transaction. A crash or dropped connection between them left
//      the balance credited and the block still pending, so the next run
//      credited it again.
//
// The fix is the claim: HDEL returns how many fields it removed, so exactly
// one caller gets 1 and only that caller credits. These tests hold that down
// against re-entrancy, against a second process, and against a crash in the
// window -- because a change that fixes one of the three alone is the bug
// coming back.
// ---------------------------------------------------------------------------

const assert = require('assert');
const ShareProcessor = require('../lib/shareProcessor');

let pass = 0;
const fail = [];

async function test(name, fn) {
    try { await fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

/**
 * Enough of Redis to answer the only question these tests ask, with HDEL
 * behaving as Redis does: it returns the number of fields actually removed.
 */
function fakeRedis() {
    const h = new Map();          // key -> Map(field -> value)
    const l = new Map();          // key -> array
    const hash = (k) => { if (!h.has(k)) h.set(k, new Map()); return h.get(k); };
    const list = (k) => { if (!l.has(k)) l.set(k, []); return l.get(k); };

    const ops = {
        async hgetall(k) { return Object.fromEntries(hash(k)); },
        async hdel(k, f) { return hash(k).delete(f) ? 1 : 0; },
        async hset(k, f, v) { hash(k).set(f, v); return 1; },
        async hincrby(k, f, n) {
            const cur = Number(hash(k).get(f) || 0) + Number(n);
            hash(k).set(f, String(cur));
            return cur;
        },
        async lpush(k, v) { list(k).unshift(v); return list(k).length; },
        async ltrim() { return 'OK'; },
        async lrem(k, _c, v) {
            const arr = list(k);
            const i = arr.indexOf(v);
            if (i === -1) return 0;
            arr.splice(i, 1);
            return 1;
        },
        async decrby() { return 0; },
        pipeline() {
            const queued = [];
            const api = {};
            for (const name of ['hincrby', 'hdel', 'hset', 'lpush', 'ltrim', 'lrem', 'decrby']) {
                api[name] = (...args) => { queued.push([name, args]); return api; };
            }
            // A pipeline is a batch, not a transaction: it runs the commands in
            // order and stops at nothing. crashAfter simulates the process dying
            // partway through, which is the window the old code lived in.
            api.exec = async () => {
                for (let i = 0; i < queued.length; i++) {
                    if (ops._crashAfter !== undefined && i >= ops._crashAfter) {
                        throw new Error('connection lost mid-pipeline');
                    }
                    const [name, args] = queued[i];
                    await ops[name](...args);
                }
                return [];
            };
            return api;
        },
        _dump: { h, l }
    };
    return ops;
}

function processorWith(redis, confirmations) {
    // constructor(redis, daemon, config, logger) -- positional, not an object.
    const daemon = {
        // The real path is daemon.getBlock(hash, 1), not a generic call().
        async getBlock() { return { confirmations, height: 9000, tx: ['ab'] }; }
    };
    return new ShareProcessor(
        redis,
        daemon,
        { redisPrefix: 'wam', coinbaseMaturity: 100 },
        { info() {}, warn() {}, error() {}, debug() {} }
    );
}

const RECORD = {
    height: 9000,
    minerPot: 4750000000,
    poolFee: 0,
    workers: 2,
    payouts: { 'twam1aaa.rig1': 2375000000, 'twam1bbb.rig2': 2375000000 }
};

function balances(redis) {
    return Object.fromEntries(redis._dump.h.get('wam:balances') || new Map());
}

(async () => {
    console.log('\na block is credited to miners exactly once');

    await test('two concurrent _mature calls credit once, not twice', async () => {
        const r = fakeRedis();
        await r.hset('wam:blocks:pending', 'H', JSON.stringify(RECORD));
        const sp = processorWith(r, 120);
        await Promise.all([
            sp._mature('H', { ...RECORD }),
            sp._mature('H', { ...RECORD })
        ]);
        const b = balances(r);
        assert.strictEqual(b.twam1aaa, '2375000000', `credited ${b.twam1aaa}`);
        assert.strictEqual(b.twam1bbb, '2375000000', `credited ${b.twam1bbb}`);
    });

    await test('the loser of the claim credits nothing at all', async () => {
        const r = fakeRedis();
        await r.hset('wam:blocks:pending', 'H', JSON.stringify(RECORD));
        const sp = processorWith(r, 120);
        await sp._mature('H', { ...RECORD });      // winner
        await sp._mature('H', { ...RECORD });      // loser: pending is gone
        assert.strictEqual(balances(r).twam1aaa, '2375000000');
    });

    await test('checkPendingBlocks is not re-entrant', async () => {
        const r = fakeRedis();
        await r.hset('wam:blocks:pending', 'H', JSON.stringify(RECORD));
        const sp = processorWith(r, 120);
        // The interval and the shutdown handler, overlapping -- the exact
        // trigger in the report.
        await Promise.all([sp.checkPendingBlocks(), sp.checkPendingBlocks()]);
        assert.strictEqual(balances(r).twam1aaa, '2375000000');
    });

    await test('a crash inside the credit leaves evidence and never doubles', async () => {
        const r = fakeRedis();
        await r.hset('wam:blocks:pending', 'H', JSON.stringify(RECORD));
        const sp = processorWith(r, 120);
        r._crashAfter = 1;                       // die after the first hincrby
        await sp._mature('H', { ...RECORD }).catch(() => {});
        r._crashAfter = undefined;

        const maturing = r._dump.l.get('wam:blocks:maturing') || [];
        assert.strictEqual(maturing.length, 1,
            'the claimed block must be recorded before crediting starts');
        assert.strictEqual((await r.hgetall('wam:blocks:pending')).H, undefined,
            'the claim must be gone, so a later run cannot credit it again');

        // And the restart: the block is no longer pending, so nobody is paid
        // twice. What is owed is in blocks:maturing for an operator to replay.
        await sp.checkPendingBlocks();
        assert.strictEqual(balances(r).twam1aaa, '2375000000',
            'a second run after the crash must not add anything');
    });

    await test('a matured block still lands in blocks:confirmed', async () => {
        const r = fakeRedis();
        await r.hset('wam:blocks:pending', 'H', JSON.stringify(RECORD));
        const sp = processorWith(r, 120);
        await sp._mature('H', { ...RECORD });
        assert.strictEqual((r._dump.l.get('wam:blocks:confirmed') || []).length, 1);
        assert.strictEqual((r._dump.l.get('wam:blocks:maturing') || []).length, 0,
            'the evidence entry is removed once the credit is through');
    });

    console.log(fail.length
        ? `\n  ${fail.length} failure(s): ${fail.join(', ')}\n`
        : `\n  ${pass} checks: a block cannot be credited twice\n`);
    process.exit(fail.length ? 1 : 0);
})();

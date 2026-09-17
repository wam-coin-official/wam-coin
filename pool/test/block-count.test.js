'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// The number of blocks a pool has found is not the length of a window.
//
// getPoolStats read lrange(blocks:confirmed, 0, 49) and published
// confirmedBlocks.length as blocksConfirmed. lrange returns at most fifty
// entries, so the moment the fiftieth block matured the dashboard said 50 and
// would have said 50 for the rest of the pool's life.
//
// It was found by watching, not by reading: the founder sat with the page for
// a day and reported that "maturing" climbed from 46 to 64 while "BLOCKS
// FOUND 50" never moved once. blocksPending came from hgetall, which has no
// window, which is exactly why one number moved and the other did not.
//
// The same mistake capped orphans at 25 and summed the treasury total over a
// truncated sample -- a money figure on a public page that quietly
// understated itself.
// ---------------------------------------------------------------------------

const assert = require('assert');
const ShareProcessor = require('../lib/shareProcessor');

let pass = 0;
const fail = [];

async function test(name, fn) {
    try { await fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

/** Enough redis to answer getPoolStats, with lrange and llen behaving as redis does. */
function fakeRedis(confirmedCount, pendingCount, devFeePerBlock = 250000000) {
    const confirmed = [];
    for (let i = 0; i < confirmedCount; i++) {
        confirmed.push(JSON.stringify({ height: 1000 + i, devFeeAmount: devFeePerBlock,
                                        minerPot: 4750000000, payouts: {} }));
    }
    const pending = {};
    for (let i = 0; i < pendingCount; i++) {
        pending[`h${i}`] = JSON.stringify({ height: 2000 + i, devFeeAmount: devFeePerBlock,
                                            minerPot: 4750000000, payouts: {} });
    }
    return {
        async lrange(key, start, stop) {
            const list = key.endsWith('blocks:confirmed') ? confirmed : [];
            return list.slice(start, stop === -1 ? undefined : stop + 1);
        },
        async llen(key) {
            return key.endsWith('blocks:confirmed') ? confirmed.length : 0;
        },
        async hgetall(key) {
            return key.endsWith('blocks:pending') ? pending : {};
        },
        async get() { return '0'; },
        async zrangebyscore() { return []; }
    };
}

function sp(redis) {
    return new ShareProcessor(redis, {}, { redisPrefix: 'wam', coinbaseMaturity: 100 },
                              { info() {}, warn() {}, error() {}, debug() {} });
}

(async () => {
    console.log('\nthe count of blocks found is the count, not a page of it');

    await test('120 matured blocks report as 120, not as 50', async () => {
        const s = await sp(fakeRedis(120, 7)).getPoolStats();
        assert.strictEqual(s.blocksConfirmed, 120,
            `reported ${s.blocksConfirmed} -- the window length leaked into the count`);
    });

    await test('the exact boundary that hid it: 50 and 51', async () => {
        assert.strictEqual((await sp(fakeRedis(50, 0)).getPoolStats()).blocksConfirmed, 50);
        assert.strictEqual((await sp(fakeRedis(51, 0)).getPoolStats()).blocksConfirmed, 51,
            'the 51st block did not appear -- this is the original bug');
    });

    await test('pending still comes from the whole hash, as it always did', async () => {
        const s = await sp(fakeRedis(120, 64)).getPoolStats();
        assert.strictEqual(s.blocksPending, 64);
    });

    await test('the treasury total covers every block, not a page of them', async () => {
        const s = await sp(fakeRedis(120, 7)).getPoolStats();
        // 127 blocks x 2.5 WAM
        assert.strictEqual(s.treasuryPaidByConsensus, 127 * 250000000,
            `summed ${s.treasuryPaidByConsensus / 1e8} WAM over a sample`);
        assert.strictEqual(s.treasuryPaidComplete, true);
    });

    await test('and says so when it cannot cover them all', async () => {
        // Above the 5000-entry trim the list no longer holds every block, and
        // a money figure must not present a partial sum as a whole one.
        const s = await sp(fakeRedis(5200, 0)).getPoolStats();
        assert.strictEqual(s.blocksConfirmed, 5200, 'the count must still be exact');
        assert.strictEqual(s.treasuryPaidComplete, false,
            'a truncated sum was reported as complete');
    });

    await test('a pool that has found nothing reports zero, not an error', async () => {
        const s = await sp(fakeRedis(0, 0)).getPoolStats();
        assert.strictEqual(s.blocksConfirmed, 0);
        assert.strictEqual(s.blocksPending, 0);
        assert.strictEqual(s.treasuryPaidByConsensus, 0);
    });

    console.log(fail.length
        ? `\n  ${fail.length} failure(s): ${fail.join(', ')}\n`
        : `\n  ${pass} checks: the dashboard counts blocks, not rows of a page\n`);
    process.exit(fail.length ? 1 : 0);
})();

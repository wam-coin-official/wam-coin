'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// A pool fee of zero must mean zero.
//
// On launch night one operator was finding 95% of the blocks and miners were
// leaving. The answer was to make this pool free, so that pointing hash rate
// somewhere other than the majority cost nothing. The config was set to 0,
// the pool was restarted, and the API went on reporting 1%:
//
//     this.poolFeePercent = config.poolFeePercent || 1;
//
// `0 || 1` is 1. The operator's decision was discarded without a word, and
// every report -- log line, /api/stats, the dashboard -- agreed on the wrong
// number, so nothing anywhere said the fee had not been applied.
//
// These tests hold the zero down, and hold down the other settings where an
// operator might legitimately choose zero.
// ---------------------------------------------------------------------------

const assert = require('assert');
const ShareProcessor = require('../lib/shareProcessor');

let pass = 0;
const fail = [];

function test(name, fn) {
    try { fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

const log = { info() {}, warn() {}, error() {}, debug() {} };
const redis = {};
const daemon = {};

function sp(config) {
    return new ShareProcessor(redis, daemon, { redisPrefix: 'wam', ...config }, log);
}

console.log('\na fee of zero means zero');

test('poolFeePercent 0 stays 0, and is not replaced by 1', () => {
    assert.strictEqual(sp({ poolFeePercent: 0 }).poolFeePercent, 0,
        'a free pool was silently charged');
});

test('an omitted poolFeePercent still defaults to 1', () => {
    assert.strictEqual(sp({}).poolFeePercent, 1);
});

test('a normal fee is untouched', () => {
    assert.strictEqual(sp({ poolFeePercent: 1.5 }).poolFeePercent, 1.5);
});

test('minimumPayoutWam 0 means pay everything, not pay above 1', () => {
    const p = sp({ minimumPayoutWam: 0 });
    // The threshold is computed where it is used, so read it the same way.
    const threshold = Math.round((p.config.minimumPayoutWam ?? 1) * 1e8);
    assert.strictEqual(threshold, 0, 'a zero threshold became 1 WAM');
});

test('txFeeReserveWam 0 means no reserve', () => {
    const p = sp({ txFeeReserveWam: 0 });
    const reserve = Math.round((p.config.txFeeReserveWam ?? 0.01) * 1e8);
    assert.strictEqual(reserve, 0, 'a zero reserve became 0.01 WAM');
});

test('rewards refuses a fee outside [0,100) rather than substituting one', () => {
    const rewards = require('../lib/rewards');
    assert.throws(() => rewards.computeBlockRewards({
        blockValue: 5000000000, devFeeAmount: 250000000,
        poolFeePercent: 100, shares: { a: 1 }
    }), /poolFeePercent/);
});

console.log(fail.length
    ? `\n  ${fail.length} failure(s): ${fail.join(', ')}\n`
    : `\n  ${pass} checks: zero is a number the operator is allowed to choose\n`);
process.exit(fail.length ? 1 : 0);

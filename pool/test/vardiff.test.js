'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// A share must never be harder than the block it is a fraction of.
//
// The pool shipped minDiff 100 against a testnet whose difficulty was
// 0.000244. The easiest share it would accept was therefore 409,600 times
// harder than a block. A miner at 450 H/s would have waited roughly thirty
// years for one.
//
// Nothing looked wrong. Blocks are accepted whatever the share target says --
// jobManager checks `isBlockCandidate` first -- so blocks arrived, payouts
// happened, the dashboard filled in. With one miner it is indistinguishable
// from a working pool, because splitting one block between one participant is
// correct however you compute it. With two it is solo mining with extra steps:
// everything to whoever got lucky, nothing to the miner who did half the work.
//
// These tests are about that one invariant and the arithmetic under it.
// ---------------------------------------------------------------------------

const assert = require('assert');
const VarDiff = require('../lib/varDiff');

let pass = 0;
const fail = [];

function test(name, fn) {
    try { fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

console.log('\n=== the share/block invariant ===');

test('with no network difficulty known, configured bounds stand', () => {
    const v = new VarDiff({ minDiff: 100, maxDiff: 2000000 });
    assert.strictEqual(v.createState(500).difficulty, 500);
    assert.strictEqual(v.createState(1).difficulty, 100, 'floor still applies');
});

test('a new miner is never started above the network difficulty', () => {
    const v = new VarDiff({ minDiff: 100, maxDiff: 2000000 });
    v.setNetworkDifficulty(0.000244140625);
    const d = v.createState(500).difficulty;
    assert.ok(d <= 0.000244140625, `started at ${d}, block costs 0.000244`);
});

test('the configured floor cannot hold difficulty above a block', () => {
    // This is the exact shipped configuration against the live testnet.
    const v = new VarDiff({ minDiff: 100, maxDiff: 2000000 });
    v.setNetworkDifficulty(0.000244140625);
    assert.ok(v._minAllowed() <= 0.000244140625,
        `floor ${v._minAllowed()} still exceeds the network difficulty`);
});

test('the floor leaves room for several shares per block', () => {
    const net = 0.000244140625;
    const v = new VarDiff({ minDiff: 100 });
    v.setNetworkDifficulty(net);
    // /16 -- enough shares per block for PPLNS to measure a contribution.
    assert.ok(v._minAllowed() <= net / 16 + 1e-12,
        `floor ${v._minAllowed()} gives fewer than 16 shares per block`);
});

test('on a mature chain the configured floor is respected', () => {
    // The regression to avoid: fixing a testnet must not drop mainnet's floor.
    const v = new VarDiff({ minDiff: 100, maxDiff: 2000000 });
    v.setNetworkDifficulty(5000000);
    assert.strictEqual(v._minAllowed(), 100, 'floor should stay where configured');
    assert.strictEqual(v.createState(500).difficulty, 500);
});

test('the ceiling is a sixteenth of a block, not a whole one', () => {
    // At exactly the network difficulty a miner submits one share per block,
    // and PPLNS divides a reward by a single sample.
    const v = new VarDiff({ minDiff: 0.0001, maxDiff: 2000000 });
    v.setNetworkDifficulty(1000);
    assert.strictEqual(v._maxAllowed(), 62.5);
    assert.ok(v.createState(999999).difficulty <= 62.5);
});

test('a new miner starts where it can actually produce shares', () => {
    // The live testnet case: difficulty 0.000244, port start 500.
    const net = 0.000244140625;
    const v = new VarDiff({ minDiff: 100, maxDiff: 2000000 });
    v.setNetworkDifficulty(net);
    const d = v.createState(500).difficulty;
    assert.ok(d <= net / 16 + 1e-12,
        `started at ${d}; needs to be at or below ${net / 16} for 16 shares/block`);
    assert.ok(d > 0, 'and still positive');
});

console.log('\n=== bad input does not widen the bounds ===');

for (const [label, value] of [
    ['null', null], ['undefined', undefined], ['zero', 0],
    ['negative', -5], ['NaN', NaN], ['Infinity', Infinity], ['a string', '500']
]) {
    test(`${label} leaves the configured bounds alone`, () => {
        const v = new VarDiff({ minDiff: 100, maxDiff: 2000000 });
        v.setNetworkDifficulty(value);
        assert.strictEqual(v._minAllowed(), 100);
        assert.strictEqual(v._maxAllowed(), 2000000);
    });
}

console.log('\n=== the controller still controls ===');

test('an idle miner is stepped down', () => {
    const v = new VarDiff({ minDiff: 0.05, targetTime: 15 });
    const s = v.createState(500);
    s.lastShare = Date.now() / 1000 - 15 * 9;    // idle past the threshold
    assert.strictEqual(v.onIdle(s), 250);
});

test('an idle miner already at the floor is left alone', () => {
    const v = new VarDiff({ minDiff: 100, targetTime: 15 });
    const s = v.createState(100);
    s.lastShare = Date.now() / 1000 - 15 * 9;
    assert.strictEqual(v.onIdle(s), null, 'should not churn at the floor');
});

test('shares arriving too fast raise the difficulty', () => {
    const v = new VarDiff({ targetTime: 15, retargetTime: 1, minDiff: 0.05, maxDiff: 1e9 });
    const s = v.createState(100);
    s.lastRetarget = Date.now() / 1000 - 100;
    for (let i = 0; i < 8; i++) { s.lastShare -= 1; v.onShare(s); }
    assert.ok(s.difficulty > 100, `difficulty stayed at ${s.difficulty}`);
});

test('a single jump is bounded', () => {
    const v = new VarDiff({ targetTime: 15, retargetTime: 1, maxJump: 4, minDiff: 0.001, maxDiff: 1e9 });
    const s = v.createState(1000);
    s.lastRetarget = Date.now() / 1000 - 100;
    s.timeBuffer = [600, 600, 600, 600];         // forty times too slow
    const next = v.onShare(s);
    assert.ok(next >= 1000 / 4 - 1e-6, `jumped to ${next}, further than 4x`);
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

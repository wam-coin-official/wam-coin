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

// ---------------------------------------------------------------------------
// And the floor must not become the ceiling.
//
// Day one of mainnet, eight hours in: all eighteen connected miners sat on
// byte-identical difficulty 0.00414, and a miner asked in the chat "why create
// a pool if it works only in solo mode?". He was describing the truth from his
// seat. _minAllowed() derived the floor from networkDiff/16 -- the same rule as
// the ceiling -- so with the shipped minDiff of 100 the band was one value wide
// and vardiff could not move anybody at all. A share at networkDiff/16 is about
// twenty-eight hours of work for a 200 H/s machine.
// ---------------------------------------------------------------------------

test('the floor is not the ceiling on a young chain', () => {
    const vd = new VarDiff({ minDiff: 0.000001, maxDiff: 2000000, targetTime: 15 });
    vd.setNetworkDifficulty(0.0755);
    const lo = vd._minAllowed();
    const hi = vd._maxAllowed();
    assert.ok(lo < hi, `the band collapsed: floor ${lo} ceiling ${hi}`);
    assert.ok(hi <= 0.0755 / 16 + 1e-12, 'a share may not cost more than 1/16 block');
});

test('a miner that never submits is walked down to the floor', () => {
    const vd = new VarDiff({ minDiff: 0.000001, maxDiff: 2000000, targetTime: 15 });
    vd.setNetworkDifficulty(0.0755);
    const st = vd.createState(1000);
    const started = st.difficulty;
    for (let i = 0; i < 40; i++) {
        st.lastShare = Date.now() / 1000 - 10000;
        vd.onIdle(st);
    }
    assert.ok(st.difficulty < started, 'the difficulty never moved');
    assert.ok(Math.abs(st.difficulty - vd._minAllowed()) < 1e-9,
        `stopped at ${st.difficulty}, floor is ${vd._minAllowed()}`);
    // 0.000001 is the smallest the 6-decimal wire rounding can express.
    assert.strictEqual(st.difficulty, 0.000001);
});

test('a floor configured above the ceiling is refused, not obeyed', () => {
    const vd = new VarDiff({ minDiff: 100, maxDiff: 2000000, targetTime: 15 });
    vd.setNetworkDifficulty(0.0755);
    assert.ok(vd._minAllowed() <= vd._maxAllowed(),
        'the floor was allowed above the ceiling');
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

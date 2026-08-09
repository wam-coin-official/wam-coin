'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// Dependency-free tests for the money-splitting logic and the serialization
// helpers.  Run with:  node pool/test/rewards.test.js

const assert = require('assert');

const {
    splitProportionally, selectPplnsWindow, computeBlockRewards, estimateHashrate
} = require('../lib/rewards');
const util = require('../lib/util');
const { seedHeightFor, blocksUntilNextSeed, BOOTSTRAP_SEED } = require('../lib/randomxSeed');
const C = require('../lib/constants');

let passed = 0;
const failures = [];

function test(name, fn) {
    try {
        fn();
        passed++;
        console.log(`  ok    ${name}`);
    } catch (err) {
        failures.push(name);
        console.log(`  FAIL  ${name}\n          ${err.message}`);
    }
}

console.log('='.repeat(72));
console.log(' WAM pool -- reward and serialization tests');
console.log('='.repeat(72));

// ---------------------------------------------------------------------------
console.log('\n[1] proportional splitting');

test('splits evenly with no dust lost', () => {
    const w = new Map([['a', 1], ['b', 1], ['c', 1]]);
    const out = splitProportionally(w, 100);
    const total = [...out.values()].reduce((x, y) => x + y, 0);
    assert.strictEqual(total, 100, 'total must be exact');
});

test('remainder goes to the largest contributor', () => {
    const w = new Map([['big', 7], ['small', 1]]);
    const out = splitProportionally(w, 10);
    assert.strictEqual(out.get('big') + out.get('small'), 10);
    // 10*7/8 = 8.75 -> 8, 10*1/8 = 1.25 -> 1, remainder 1 -> big
    assert.strictEqual(out.get('big'), 9);
    assert.strictEqual(out.get('small'), 1);
});

test('never loses a single base unit across many random splits', () => {
    for (let trial = 0; trial < 500; trial++) {
        const n = 1 + Math.floor(Math.random() * 20);
        const w = new Map();
        for (let i = 0; i < n; i++) w.set(`w${i}`, Math.random() * 1000 + 0.0001);
        const amount = Math.floor(Math.random() * 5e9) + 1;
        const out = splitProportionally(w, amount);
        const total = [...out.values()].reduce((x, y) => x + y, 0);
        assert.strictEqual(total, amount, `trial ${trial}: ${total} !== ${amount}`);
    }
});

test('ignores zero and negative weights', () => {
    const w = new Map([['a', 5], ['b', 0], ['c', -3]]);
    const out = splitProportionally(w, 100);
    assert.strictEqual(out.get('a'), 100);
    assert.ok(!out.has('b') || out.get('b') === 0);
});

test('returns empty for a zero amount', () => {
    assert.strictEqual(splitProportionally(new Map([['a', 1]]), 0).size, 0);
});

// ---------------------------------------------------------------------------
console.log('\n[2] PPLNS window');

test('window stops once N difficulty is covered', () => {
    const shares = [
        { worker: 'a', difficulty: 100 },
        { worker: 'b', difficulty: 100 },
        { worker: 'c', difficulty: 100 }
    ];
    const { weights, covered, used } = selectPplnsWindow(shares, 150);
    assert.strictEqual(covered, 150);
    assert.strictEqual(used, 2);
    assert.strictEqual(weights.get('a'), 100);
    assert.strictEqual(weights.get('b'), 50, 'the straddling share is partially credited');
    assert.ok(!weights.has('c'), 'shares beyond the window are excluded');
});

test('aggregates repeated workers', () => {
    const shares = [
        { worker: 'a', difficulty: 10 },
        { worker: 'b', difficulty: 10 },
        { worker: 'a', difficulty: 10 }
    ];
    const { weights } = selectPplnsWindow(shares, 100);
    assert.strictEqual(weights.get('a'), 20);
    assert.strictEqual(weights.get('b'), 10);
});

test('short buffer covers only what exists', () => {
    const { covered, used } = selectPplnsWindow([{ worker: 'a', difficulty: 5 }], 1000);
    assert.strictEqual(covered, 5);
    assert.strictEqual(used, 1);
});

// ---------------------------------------------------------------------------
console.log('\n[3] block reward computation -- the 5% treasury boundary');

const COIN = C.COIN;
const SUBSIDY = 50 * COIN;              // epoch 0
const DEVFEE = SUBSIDY * 0.05;          // 2.5 WAM, paid by consensus
const DISTRIBUTABLE = SUBSIDY - DEVFEE; // 47.5 WAM

test('treasury amount is exactly 2.5 WAM at epoch 0', () => {
    assert.strictEqual(DEVFEE, 250000000);
    assert.strictEqual(DISTRIBUTABLE, 4750000000);
});

test('miners are paid from the distributable value, not the coinbase value', () => {
    const r = computeBlockRewards({
        mode: 'prop',
        blockValue: DISTRIBUTABLE,
        coinbaseValue: SUBSIDY,
        devFeeAmount: DEVFEE,
        poolFeePercent: 0,
        roundContributions: new Map([['a', 1]])
    });
    assert.strictEqual(r.payouts.get('a'), DISTRIBUTABLE);
    assert.strictEqual(r.totalPaid, DISTRIBUTABLE);
});

test('REJECTS being handed the raw coinbase value', () => {
    assert.throws(() => computeBlockRewards({
        mode: 'prop',
        blockValue: SUBSIDY,             // <-- the mistake
        coinbaseValue: SUBSIDY,
        devFeeAmount: DEVFEE,
        roundContributions: new Map([['a', 1]])
    }), /must never be distributed to miners/);
});

test('pool fee is taken after the treasury, not before', () => {
    const r = computeBlockRewards({
        mode: 'prop',
        blockValue: DISTRIBUTABLE,
        poolFeePercent: 1,
        roundContributions: new Map([['a', 1]])
    });
    assert.strictEqual(r.poolFee, Math.floor(DISTRIBUTABLE * 0.01));
    assert.strictEqual(r.poolFee + r.totalPaid, DISTRIBUTABLE,
        'pool fee plus payouts must reconstruct the distributable value exactly');
});

test('PPLNS pays proportionally to work inside the window', () => {
    const shares = [];
    for (let i = 0; i < 100; i++) shares.push({ worker: 'a', difficulty: 1 });
    for (let i = 0; i < 300; i++) shares.push({ worker: 'b', difficulty: 1 });

    const r = computeBlockRewards({
        mode: 'pplns',
        blockValue: DISTRIBUTABLE,
        poolFeePercent: 0,
        shares,
        networkDifficulty: 200,
        pplnsMultiplier: 2       // window = 400 -> the whole buffer
    });

    assert.strictEqual(r.window.covered, 400);
    const a = r.payouts.get('a');
    const b = r.payouts.get('b');
    assert.strictEqual(a + b, DISTRIBUTABLE);
    assert.ok(Math.abs(b / a - 3) < 0.001, `b should be ~3x a, got ${b / a}`);
});

test('PPLNS falls back to the round when the buffer is empty', () => {
    const r = computeBlockRewards({
        mode: 'pplns',
        blockValue: DISTRIBUTABLE,
        shares: [],
        roundContributions: new Map([['solo', 1]]),
        networkDifficulty: 1000
    });
    assert.strictEqual(r.payouts.get('solo'), DISTRIBUTABLE);
});

test('rejects an out-of-range pool fee', () => {
    assert.throws(() => computeBlockRewards({
        blockValue: DISTRIBUTABLE, poolFeePercent: 100,
        roundContributions: new Map([['a', 1]]), mode: 'prop'
    }), /poolFeePercent/);
});

test('full-chain accounting: coinbase == treasury + pool fee + miners', () => {
    const r = computeBlockRewards({
        mode: 'pplns',
        blockValue: DISTRIBUTABLE,
        coinbaseValue: SUBSIDY,
        devFeeAmount: DEVFEE,
        poolFeePercent: 1.5,
        shares: [{ worker: 'x', difficulty: 500 }, { worker: 'y', difficulty: 500 }],
        networkDifficulty: 500
    });
    assert.strictEqual(DEVFEE + r.poolFee + r.totalPaid, SUBSIDY);
});

// ---------------------------------------------------------------------------
console.log('\n[4] hashrate estimation');

test('uses the RandomX difficulty-1 convention', () => {
    // 1 share of difficulty 1000 in 1 second == 1000 * 2^32 H/s
    const hr = estimateHashrate([{ difficulty: 1000 }], 1);
    assert.strictEqual(hr, 1000 * 4294967296);
});

test('zero shares gives zero hashrate', () => {
    assert.strictEqual(estimateHashrate([], 60), 0);
});

// ---------------------------------------------------------------------------
console.log('\n[5] serialization helpers (must match the C++ node)');

test('varint matches Bitcoin CompactSize', () => {
    assert.strictEqual(util.varIntBuffer(0).toString('hex'), '00');
    assert.strictEqual(util.varIntBuffer(252).toString('hex'), 'fc');
    assert.strictEqual(util.varIntBuffer(253).toString('hex'), 'fdfd00');
    assert.strictEqual(util.varIntBuffer(65536).toString('hex'), 'fe00000100');
});

test('BIP34 height encoding', () => {
    // Height 1 -> OP_1. This test previously asserted '0101', a one-byte data
    // push, which is what the code did and what consensus rejects. An assertion
    // is only as good as the thing it was checked against; see section [9].
    assert.strictEqual(util.serializeHeight(1).toString('hex'), '51');
    // Height 200000 = 0x030d40 -> little-endian 400d03
    assert.strictEqual(util.serializeHeight(200000).toString('hex'), '03400d03');
});

test('base58check decodes a known Bitcoin address', () => {
    const { version, hash } = util.addressToHash160('1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa');
    assert.strictEqual(version, 0);
    assert.strictEqual(hash.toString('hex'), '62e907b15cbf27d5425399ebf6f0fb50ebb88f18');
});

test('rejects a mistyped address', () => {
    assert.throws(() => util.addressToHash160('1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb'),
                  /checksum/);
});

test('P2PKH script shape', () => {
    const s = util.p2pkhScript(Buffer.alloc(20, 0xab));
    assert.strictEqual(s.length, 25);
    assert.strictEqual(s.subarray(0, 3).toString('hex'), '76a914');
    assert.strictEqual(s.subarray(23).toString('hex'), '88ac');
});

test('nBits -> target matches the Python tooling', () => {
    assert.strictEqual(
        util.bitsToTarget(0x1d00ffff).toString(16).padStart(64, '0'),
        '00000000ffff0000000000000000000000000000000000000000000000000000');
    assert.strictEqual(
        util.bitsToTarget(0x1e0ffff0).toString(16).padStart(64, '0'),
        '00000ffff0000000000000000000000000000000000000000000000000000000');
});

test('merkle branch of a single transaction', () => {
    // With one non-coinbase tx the branch is just that tx.
    const tx = util.sha256d(Buffer.from('deadbeef', 'hex'));
    const branch = util.buildMerkleBranch([tx]);
    assert.strictEqual(branch.length, 1);
    assert.ok(branch[0].equals(tx));
});

test('applying an empty branch returns the coinbase hash itself', () => {
    const cb = util.sha256d(Buffer.from('00', 'hex'));
    assert.ok(util.applyMerkleBranch(cb, []).equals(cb));
});

test('difficulty -> target -> difficulty round-trips', () => {
    for (const d of [1, 16, 1000, 65536, 1234567]) {
        const t = util.difficultyToTarget(d);
        const back = util.targetToDifficulty(t);
        assert.ok(Math.abs(back - d) / d < 1e-6, `${d} -> ${back}`);
    }
});

// ---------------------------------------------------------------------------
console.log('\n[6] RandomX seed rotation (must match randomx_hash.cpp)');

test('bootstrap seed is SHA256 of the fixed key', () => {
    const expected = require('crypto').createHash('sha256')
        .update('WAM/RandomX/epoch-0/2026').digest('hex');
    assert.strictEqual(BOOTSTRAP_SEED.toString('hex'), expected);
});

test('every height inside the lag uses the bootstrap seed', () => {
    for (let h = 0; h <= C.RANDOMX_EPOCH_LAG; h++) {
        assert.strictEqual(seedHeightFor(h), 0, `height ${h}`);
    }
});

test('seed height is a multiple of the epoch length', () => {
    for (const h of [65, 2000, 2112, 4096, 5000, 100000]) {
        const s = seedHeightFor(h);
        assert.strictEqual(s % C.RANDOMX_EPOCH_BLOCKS, 0, `height ${h} -> ${s}`);
        assert.ok(s <= h - C.RANDOMX_EPOCH_LAG || s === 0,
            `seed ${s} must be at least ${C.RANDOMX_EPOCH_LAG} blocks behind ${h}`);
    }
});

test('the seed is stable across an entire epoch', () => {
    const base = 5000;
    const s = seedHeightFor(base);
    for (let h = base; seedHeightFor(h) === s; h++) {
        assert.ok(h - base < C.RANDOMX_EPOCH_BLOCKS + 1, 'epoch ran too long');
    }
});

test('blocksUntilNextSeed is positive and bounded', () => {
    for (const h of [1, 100, 2000, 2100, 50000]) {
        const n = blocksUntilNextSeed(h);
        assert.ok(n > 0 && n <= C.RANDOMX_EPOCH_BLOCKS + C.RANDOMX_EPOCH_LAG,
            `height ${h} -> ${n}`);
        assert.notStrictEqual(seedHeightFor(h + n), seedHeightFor(h));
    }
});

// ---------------------------------------------------------------------------
console.log('\n[7] constants agree with consensus');

test('halving interval is 200,000', () => {
    assert.strictEqual(C.SUBSIDY_HALVING_INTERVAL, 200000);
});
test('initial subsidy is 50 WAM', () => {
    assert.strictEqual(C.INITIAL_BLOCK_SUBSIDY_WAM, 50);
});
test('dev fee is 5%', () => {
    assert.strictEqual(C.DEVFEE_PERCENT, 5);
});
test('20,000,000 WAM is mined in total', () => {
    assert.strictEqual(C.SUBSIDY_HALVING_INTERVAL * C.INITIAL_BLOCK_SUBSIDY_WAM * 2,
                       C.MAX_MONEY_WAM - C.GENESIS_PREMINE_WAM);
});
test("mainnet addresses start with 'W'", () => {
    assert.strictEqual(C.ADDRESS_VERSIONS.mainnet.pubkey, 73);
    assert.strictEqual(C.ADDRESS_VERSIONS.mainnet.firstChar, 'W');
});

// ---------------------------------------------------------------------------
console.log('\n[8] treasury fee sunset');

test('sunset height is 400,000', () => {
    assert.strictEqual(C.DEVFEE_LAST_HEIGHT, 400000);
});

test('the sunset spans more than one halving epoch', () => {
    // If it were shortened to one epoch the published 750,000 WAM lifetime
    // figure in the whitepaper would silently become 500,000.
    assert.ok(C.DEVFEE_LAST_HEIGHT > C.SUBSIDY_HALVING_INTERVAL,
        'the fee must survive at least one halving for the published total to hold');
});

test('lifetime treasury income is exactly 750,000 WAM', () => {
    let total = 0;
    for (let e = 0; e < C.MAX_HALVINGS; e++) {
        const subsidy = Math.floor(C.INITIAL_BLOCK_SUBSIDY_WAM * COIN / 2 ** e);
        if (subsidy === 0) break;
        const first = e * C.SUBSIDY_HALVING_INTERVAL + 1;
        if (first > C.DEVFEE_LAST_HEIGHT) break;
        const last = Math.min((e + 1) * C.SUBSIDY_HALVING_INTERVAL, C.DEVFEE_LAST_HEIGHT);
        total += (last - first + 1) * Math.floor(subsidy * C.DEVFEE_PERCENT / 100);
    }
    assert.strictEqual(total, 750000 * COIN);
});

test('founder + operating totals 12.50% of the cap', () => {
    const founder = (C.GENESIS_PREMINE_WAM + 750000) * COIN;
    const cap = C.MAX_MONEY_WAM * COIN;
    assert.strictEqual(founder, 2750000 * COIN);
    assert.ok(Math.abs(100 * founder / cap - 12.5) < 1e-9);
});

test('public mining share is 87.50%', () => {
    const mining = (C.MAX_MONEY_WAM - C.GENESIS_PREMINE_WAM - 750000) * COIN;
    assert.strictEqual(mining, 19250000 * COIN);
    assert.ok(Math.abs(100 * mining / (C.MAX_MONEY_WAM * COIN) - 87.5) < 1e-9);
});

test('after the sunset the pool must distribute the WHOLE coinbase', () => {
    // Past height 400,000 the daemon reports devfee.amount = 0, so the
    // distributable value equals the full coinbase value. The reward
    // calculator must accept that rather than tripping its own guard.
    const subsidy = 12.5 * COIN;
    const r = computeBlockRewards({
        mode: 'prop',
        blockValue: subsidy,
        coinbaseValue: subsidy,
        devFeeAmount: 0,          // sunset
        poolFeePercent: 0,
        roundContributions: new Map([['a', 1]])
    });
    assert.strictEqual(r.payouts.get('a'), subsidy);
    assert.strictEqual(r.totalPaid, subsidy);
});

// ---------------------------------------------------------------------------
console.log('\n[8] the coinbase must claim the whole reward');

// These exist because of a bug that was live on regtest and would have been
// live at launch. The daemon reported `coinbasevalue` as the miner's share
// alone rather than the BIP22 total, the pool subtracted the treasury from it
// a second time, and every block the pool mined quietly failed to claim 5% of
// its own subsidy. Nothing errored. Pool miners simply earned 90% of the
// schedule while solo miners earned 95%, and the difference was destroyed.

const BlockTemplate = require('../lib/blockTemplate');

const TEMPLATE_OPTS = {
    // A real regtest address, so addressToScript() is exercised for real.
    poolAddress: 'wamrt1qwpz49ds2qwtkt7m0claxr03naqqjmx8c48qj39',
    netVersions: C.ADDRESS_VERSIONS.regtest,
    coinbaseSignature: '/WAM-Pool/',
    extranonce1Size: 4
};

// SUBSIDY (50 WAM, epoch 0) is already defined above.
const TREASURY = (SUBSIDY * C.DEVFEE_PERCENT) / 100;

/** A template shaped the way BIP22 says: coinbasevalue is the TOTAL. */
function grossTemplate(overrides = {}) {
    return Object.assign({
        height: 500,
        version: 0x20000000,
        curtime: 1789430400,
        bits: '207fffff',
        previousblockhash: '00'.repeat(32),
        transactions: [],
        coinbasevalue: SUBSIDY,
        devfee: {
            amount: TREASURY,
            script: '76a914' + '11'.repeat(20) + '88ac',
            percent: C.DEVFEE_PERCENT
        }
    }, overrides);
}

test('a BIP22 template leaves nothing unclaimed', () => {
    const t = new BlockTemplate(grossTemplate(), TEMPLATE_OPTS);
    assert.strictEqual(t.devFeeAmount, TREASURY);
    assert.strictEqual(t.distributableValue, SUBSIDY - TREASURY);
    assert.strictEqual(t.devFeeAmount + t.distributableValue, SUBSIDY);
});

test('refuses a daemon that reports coinbasevalue net of the treasury', () => {
    const bad = grossTemplate({ coinbasevalue: SUBSIDY - TREASURY });
    assert.throws(() => new BlockTemplate(bad, TEMPLATE_OPTS),
                  /treasury output does not match/);
});

test('fees belong to the miner and never to the treasury', () => {
    const fee = 12345;
    const t = new BlockTemplate(grossTemplate({
        coinbasevalue: SUBSIDY + fee,
        transactions: [{ txid: 'aa'.repeat(32), data: '00', fee }]
    }), TEMPLATE_OPTS);

    assert.strictEqual(t.devFeeAmount, TREASURY);
    assert.strictEqual(t.distributableValue, SUBSIDY + fee - TREASURY);
});

test('refuses a chain whose treasury percentage differs from this build', () => {
    const bad = grossTemplate();
    bad.devfee.percent = C.DEVFEE_PERCENT + 5;
    assert.throws(() => new BlockTemplate(bad, TEMPLATE_OPTS),
                  new RegExp(`built for ${C.DEVFEE_PERCENT}%`));
});

test('after the sunset the whole coinbase is distributable', () => {
    const t = new BlockTemplate(grossTemplate({
        height: C.DEVFEE_LAST_HEIGHT + 1,
        devfee: { amount: 0, script: '76a914' + '11'.repeat(20) + '88ac', percent: C.DEVFEE_PERCENT }
    }), TEMPLATE_OPTS);

    assert.strictEqual(t.devFeeAmount, 0);
    assert.strictEqual(t.distributableValue, SUBSIDY);
});

// ---------------------------------------------------------------------------
console.log('\n[9] BIP34 height prefix');

// Consensus compares our scriptSig against `CScript() << nHeight` byte for
// byte, and CScript turns 0 and 1..16 into single opcodes rather than data
// pushes. A pool that pushes them as data mines blocks that are perfectly
// valid in every other respect and are rejected with bad-cb-height -- which
// only ever happens on the first sixteen blocks of a chain. In other words,
// only on launch day, and only for the blocks that get the chain moving.

test('heights 1..16 are OP_N, not a data push', () => {
    assert.strictEqual(util.serializeHeight(1).toString('hex'), '51');   // OP_1
    assert.strictEqual(util.serializeHeight(2).toString('hex'), '52');
    assert.strictEqual(util.serializeHeight(15).toString('hex'), '5f');
    assert.strictEqual(util.serializeHeight(16).toString('hex'), '60');  // OP_16
});

test('height 0 is OP_0', () => {
    assert.strictEqual(util.serializeHeight(0).toString('hex'), '00');
});

test('height 17 is where data pushes begin', () => {
    assert.strictEqual(util.serializeHeight(17).toString('hex'), '0111');
    assert.strictEqual(util.serializeHeight(127).toString('hex'), '017f');
});

test('a high bit gets a sign byte, as CScriptNum requires', () => {
    assert.strictEqual(util.serializeHeight(128).toString('hex'), '028000');
    assert.strictEqual(util.serializeHeight(255).toString('hex'), '02ff00');
});

test('multi-byte heights are little-endian', () => {
    assert.strictEqual(util.serializeHeight(256).toString('hex'), '020001');
    assert.strictEqual(util.serializeHeight(400000).toString('hex'), '03801a06');
});

// ---------------------------------------------------------------------------
console.log('\n' + '='.repeat(72));
if (failures.length) {
    console.log(` ${failures.length} FAILED: ${failures.join(', ')}`);
    process.exit(1);
}
console.log(` ALL ${passed} TESTS PASSED`);

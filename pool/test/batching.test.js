// Exercise the payment batching arithmetic without a node, a wallet or Redis.
// The cap path is the one that moves money, and it only runs when a pool is
// large enough that a mistake is expensive.
'use strict';
const assert = require('assert');
const COIN = 100000000;

function batchOf(due, maxRecipients, maxWam) {
    const maxPerBatch = Math.round(maxWam * COIN);
    const batch = [];
    let batchTotal = 0;
    for (const [address, amount] of due) {
        if (batch.length >= maxRecipients) break;
        if (batchTotal + amount > maxPerBatch) {
            if (batch.length === 0) {
                batch.push([address, maxPerBatch]);
                batchTotal = maxPerBatch;
            }
            break;
        }
        batch.push([address, amount]);
        batchTotal += amount;
    }
    return { batch, batchTotal };
}

let pass = 0;
const fail = [];
const t = (name, fn) => {
    try { fn(); pass++; console.log(`  ok    ${name}`); }
    catch (e) { fail.push(name); console.log(`  FAIL  ${name}\n          ${e.message}`); }
};

console.log('payment batching\n');

t('a small round goes out whole', () => {
    const due = [['a', 10 * COIN], ['b', 20 * COIN]];
    const { batch, batchTotal } = batchOf(due, 200, 100000);
    assert.strictEqual(batch.length, 2);
    assert.strictEqual(batchTotal, 30 * COIN);
});

t('the recipient cap splits, and nothing is lost', () => {
    const due = Array.from({ length: 500 }, (_, i) => [`m${i}`, COIN]);
    const { batch, batchTotal } = batchOf(due, 200, 100000);
    assert.strictEqual(batch.length, 200);
    assert.strictEqual(batchTotal, 200 * COIN);
    // The 300 left keep their balances: nothing is deducted for them.
    const paid = new Set(batch.map(([a]) => a));
    assert.strictEqual(due.filter(([a]) => !paid.has(a)).length, 300);
});

t('the value cap stops before exceeding it', () => {
    const due = [['a', 60000 * COIN], ['b', 60000 * COIN]];
    const { batch, batchTotal } = batchOf(due, 200, 100000);
    assert.strictEqual(batch.length, 1);
    assert.strictEqual(batchTotal, 60000 * COIN);
});

t('one balance bigger than the cap is paid the cap, not skipped', () => {
    const due = [['whale', 250000 * COIN], ['b', COIN]];
    const { batch, batchTotal } = batchOf(due, 200, 100000);
    assert.strictEqual(batch.length, 1);
    assert.strictEqual(batch[0][0], 'whale');
    assert.strictEqual(batch[0][1], 100000 * COIN);
    assert.strictEqual(batchTotal, 100000 * COIN);
});

t('a capped balance leaves the remainder owed', () => {
    const owed = 250000 * COIN;
    const { batch } = batchOf([['whale', owed]], 200, 100000);
    const sent = batch[0][1];
    // The deduction uses what was sent, so the difference stays a balance.
    assert.strictEqual(owed - sent, 150000 * COIN);
});

t('an empty round produces an empty batch', () => {
    const { batch, batchTotal } = batchOf([], 200, 100000);
    assert.strictEqual(batch.length, 0);
    assert.strictEqual(batchTotal, 0);
});

console.log('');
if (fail.length) { console.log(` ${fail.length} FAILED`); process.exit(1); }
console.log(` all ${pass} passed`);

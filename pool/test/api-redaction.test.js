// Every /api/* response, checked for a full payout address.
//
// Written 2026-09-13 from an independent reviewer's report: /api/miners
// redacted and its three siblings did not, and site/pool/index.html already
// told the world otherwise. His tests are here almost verbatim, plus two he
// did not write -- idempotence, because /api/miners now redacts twice, and
// "nothing else is touched", because a walker that rewrites keys is one typo
// away from eating the numbers beside them.
//
// The first version of this file pulled the two functions out of api.js with
// eval(). Under 'use strict' that defines nothing, so six tests reported
// "redactIdentities is not defined" -- which was the honest answer, and would
// have been a silent pass if eval had half-worked. api.js exports them now.
'use strict';
const assert = require('assert');
const { redactIdentities } = require('../lib/api');

const ADDR = 'twam1qzrjwqy8m04ulda604pn7qa5txe0uhkzv6jsu5y';

function noFullAddress(obj, where) {
    const hit = JSON.stringify(obj).match(/[tw]wam1[a-z0-9]{20,}/);
    assert(!hit, `${where}: a full address survived: ${hit && hit[0]}`);
}

let failures = 0;
function check(name, fn) {
    try { fn(); console.log('  ok    ' + name); }
    catch (e) { failures++; console.log('  FAIL  ' + name + '\n          ' + e.message); }
}

console.log('\nno /api response may carry a full payout address');

check('/api/hashrate -- the workers map is keyed by identity', () => {
    const out = redactIdentities({
        windowSeconds: 600,
        workers: { [ADDR + '.rig1']: { hashrate: 1, shares: 5 } }
    });
    noFullAddress(out, 'hashrate');
    assert(Object.keys(out.workers)[0].includes('…'), 'the key was not redacted');
    assert.strictEqual(out.windowSeconds, 600, 'a number beside it was altered');
    assert.strictEqual(out.workers[Object.keys(out.workers)[0]].shares, 5, 'the value was altered');
});

check('/api/blocks -- finder names the address that found the block', () => {
    const out = redactIdentities({
        confirmed: [{ height: 9130, finder: ADDR + '.rig1' }],
        pending: [{ height: 9131, finder: ADDR }],
        orphaned: []
    });
    noFullAddress(out, 'blocks');
    for (const b of [...out.confirmed, ...out.pending]) {
        assert(b.finder.includes('…') || b.finder.length <= 16, 'finder not redacted');
    }
    assert.strictEqual(out.confirmed[0].height, 9130, 'the height was altered');
});

check('/api/payments -- payouts is keyed by address, beside the txid', () => {
    const txid = 'ab'.repeat(32);
    const out = redactIdentities({ payments: [{ txid, time: 1, payouts: { [ADDR]: 12.5 } }] });
    noFullAddress(out, 'payments');
    assert.strictEqual(out.payments[0].txid, txid, 'the txid must survive: it is public anyway');
    assert.strictEqual(Object.values(out.payments[0].payouts)[0], 12.5, 'the amount was altered');
});

check('/api/miners -- redacting an already redacted value changes nothing', () => {
    const once = redactIdentities({ miners: [{ worker: ADDR + '.rig1' }] });
    const twice = redactIdentities(once);
    assert.deepStrictEqual(once, twice, 'redactWorker is not idempotent');
    noFullAddress(twice, 'miners');
});

check('a label after the dot is kept -- it identifies nothing on the chain', () => {
    const out = redactIdentities({ workers: { [ADDR + '.basement-rig']: {} } });
    assert(Object.keys(out.workers)[0].endsWith('.basement-rig'), 'the label was eaten');
});

check('nothing else is touched -- short keys, numbers, booleans, nulls', () => {
    const body = {
        chain: 'test', blocks: 9130, ok: true, nothing: null,
        nested: [{ a: 1 }, { b: 'short' }], poolHashrate: 6012.954214400006
    };
    assert.deepStrictEqual(redactIdentities(body), body);
});

check('a bare address with no label is still redacted', () => {
    const out = redactIdentities({ workers: { [ADDR]: { shares: 1 } } });
    noFullAddress(out, 'bare address');
});

console.log(failures
    ? `\n  ${failures} failure(s)\n`
    : '\n  every identity field and every identity-keyed map is redacted\n');
process.exit(failures ? 1 : 0);

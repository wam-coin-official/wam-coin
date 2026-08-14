'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// The network page must never publish a peer's address.
//
// Someone running a WAM node is doing the project a favour. Publishing where
// they are turns that into a target list -- for a denial of service, for an
// eclipse attempt, or for whoever objects to the software where they live.
// The page exists to show that the network is more than one machine; it must
// not do so at the expense of the people who make that true.
//
// So the whole output is searched for anything that looks like an address,
// with a single exception: our own seeds, whose addresses are already in
// public DNS because we chose to put them there.
//
// A test that checks specific fields would pass while a future field leaks.
// This searches the serialised payload, so it fails whatever route the leak
// takes.
// ---------------------------------------------------------------------------

const assert = require('assert');
const net = require('../lib/network');

let pass = 0;
const fail = [];

function test(name, fn) {
    try { fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

const now = () => Math.floor(Date.now() / 1000);

const PEERS = [
    { addr: '169.58.159.165:19555', inbound: false, subver: '/WAM:0.1.0/', conntime: now() - 7200 },
    { addr: '5.223.52.200:19555',   inbound: false, subver: '/WAM:0.1.0/', conntime: now() - 3600 },
    { addr: '41.254.73.73:56797',   inbound: true,  subver: '/WAM:0.1.0/', conntime: now() - 600 },
    { addr: '203.0.113.42:19555',   inbound: true,  subver: '/WAM:0.1.0/', conntime: now() - 60 },
    { addr: '[2001:db8::dead]:19555', inbound: true, subver: '/WAM:0.2.0/', conntime: now() - 30 },
    { addr: 'abcdefghijklmnop.onion:19555', inbound: false, subver: '/WAM:0.1.0/', conntime: now() - 10 }
];

console.log('\n=== nothing leaks ===');

test('no third-party address appears anywhere in the payload', () => {
    const out = JSON.stringify(net.build(PEERS, new Array(50), null));
    for (const secret of ['41.254.73.73', '203.0.113.42', '2001:db8::dead',
                          'abcdefghijklmnop.onion']) {
        assert.ok(!out.includes(secret), `payload contains ${secret}`);
    }
});

test('not even a truncated one', () => {
    // "Just the first two octets" is still a location.
    const out = JSON.stringify(net.build(PEERS, [], null));
    for (const prefix of ['41.254', '203.0', '2001:db8']) {
        assert.ok(!out.includes(prefix), `payload contains the prefix ${prefix}`);
    }
});

test('port numbers of third parties do not leak either', () => {
    // A source port plus a timestamp is a correlation handle.
    const out = JSON.stringify(net.build(PEERS, [], null));
    assert.ok(!out.includes('56797'), 'payload contains a peer source port');
});

test('our own seeds ARE named, because their addresses are public DNS', () => {
    const out = net.build(PEERS, [], null);
    const where = out.seeds.map((s) => s.where).sort();
    assert.deepStrictEqual(where, ['France', 'Singapore']);
});

test('but even our seeds are named by place, not by address', () => {
    const out = JSON.stringify(net.build(PEERS, [], null));
    assert.ok(!out.includes('169.58.159.165'), 'seed address is in the payload');
    assert.ok(!out.includes('5.223.52.200'), 'seed address is in the payload');
});

console.log('\n=== the counts are right ===');

test('every peer is counted exactly once', () => {
    const o = net.build(PEERS, [], null);
    const total = o.byType.ipv4 + o.byType.ipv6 + o.byType.onion + o.byType.seed;
    assert.strictEqual(o.connected, PEERS.length);
    assert.strictEqual(total, PEERS.length);
});

test('inbound and outbound add up', () => {
    const o = net.build(PEERS, [], null);
    assert.strictEqual(o.inbound + o.outbound, o.connected);
    assert.strictEqual(o.inbound, 3);
});

test('onion peers are recognised, not counted as ipv4', () => {
    assert.strictEqual(net.classify('abcdefghijklmnop.onion:19555').kind, 'onion');
});

test('ipv6 is recognised, not counted as ipv4', () => {
    assert.strictEqual(net.classify('[2001:db8::1]:19555').kind, 'ipv6');
});

test('known addresses are reported separately from connected', () => {
    // The honest measure of network size: addresses this node has heard of,
    // whether or not anyone is online right now.
    const o = net.build(PEERS, new Array(137), null);
    assert.strictEqual(o.known, 137);
    assert.notStrictEqual(o.known, o.connected);
});

test('versions are tallied', () => {
    const o = net.build(PEERS, [], null);
    const v = Object.fromEntries(o.versions.map((x) => [x.version, x.count]));
    assert.strictEqual(v['/WAM:0.1.0/'], 5);
    assert.strictEqual(v['/WAM:0.2.0/'], 1);
});

console.log('\n=== it survives a node that answers badly ===');

for (const [label, peers, known] of [
    ['no peers at all', [], []],
    ['null from the RPC', null, null],
    ['a peer with no addr', [{ inbound: true }], []],
    ['a peer with no conntime', [{ addr: '198.51.100.1:19555', inbound: true }], []]
]) {
    test(`${label} does not throw`, () => {
        const o = net.build(peers, known, null);
        assert.ok(typeof o.connected === 'number');
    });
}

console.log('\n' + '='.repeat(66));
if (fail.length === 0) {
    console.log(`\x1b[32m${pass} passed\x1b[0m`);
} else {
    console.log(`\x1b[31m${fail.length} failed\x1b[0m, ${pass} passed`);
    fail.forEach((f) => console.log(`  - ${f}`));
}
console.log('='.repeat(66));
process.exit(fail.length === 0 ? 0 : 1);

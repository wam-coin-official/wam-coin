'use strict';
// ===========================================================================
//  Which messages are public, and which are the operator's alone
// ===========================================================================
//
//      node bots/test/routing.test.js
//
//  Until 4 September 2026 every message went to every channel. Measured over
//  the channel's whole life: 147 posts, 21 of them the daily heartbeat and 126
//  the chain reporting that it had stopped. Eighty-six per cent of everything
//  WAM had ever said in public was "no new block for an hour", about a test
//  network whose entire hashrate is one laptop and one server.
//
//  Stalls and recoveries now go to the operator's own chat. They still fire
//  every time; they are not published. This is the test that keeps it that
//  way, because the failure it guards against is silent in both directions:
//  a stall published by accident is embarrassing, and a stall marked private
//  that quietly stops being sent at all is worse.
//
//  IT TESTS tick() AND applyBanner() TOGETHER, AND THAT IS THE POINT
//
//  The first version called tick() alone and passed six times. Meanwhile the
//  real bot published stalls at 07:51, 08:51, 09:51 and 09:52 on 4 September,
//  hours after the routing was deployed -- because between tick() and the send
//  loop, applyBanner() rewrites every message to carry the chain banner. That
//  makes NEW strings, and opsOnly was a Set of the old ones, so every lookup
//  failed and every private message went to the channel.
//
//  A test that stops one layer above the bug proves the bug is absent in the
//  layer that does not have it. Every case below runs the messages through
//  the banner first, as the bot does.
// ===========================================================================

const assert = require('assert');
const A = require('../announce');

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log(`  ok    ${name}`); passed++; }
    catch (e) { console.log(`  FAIL  ${name}\n        ${e.message}`); failed++; }
}

const rpc = (height) => ({
    async call(m) {
        if (m === 'getblockchaininfo')
            return { blocks: height, chain: 'test', difficulty: 1, bestblockhash: 'aa' };
        if (m === 'getmininginfo')  return { networkhashps: 100 };
        if (m === 'getsupplyinfo')  return null;
        if (m === 'getrandomxinfo') return null;
        if (m === 'getblockheader') return { time: Math.floor(Date.now() / 1000) };
        return {};
    }
});

const cfg = {
    heartbeatHours: 24, heartbeatHourUtc: 12, stallMinutes: 60,
    milestoneHeights: [], githubRepo: null,
    opsChatId: 'OPS', telegram: { token: 'x', chatId: 'PUBLIC' }
};

// The banner is now the first line of every message, so a heading is looked
// for anywhere in the text rather than at the top.
const has = (m, t) => String(m).replace(/<[^>]*>/g, '').includes(t);

(async () => {
    const now = Date.now();

    console.log('\n=== a chain that has not moved for two hours ===');
    const stalled = { lastHeight: 5000, lastHeightAt: now - 120 * 60000,
                      lastHeartbeatAt: now, stallAnnounced: false,
                      milestonesSeen: [] };
    const r = A.applyBanner(await A.tick(cfg, rpc(5000), stalled, () => {}));
    test('the stall alert is produced', () => {
        assert.ok(r.messages.some((m) => has(m, 'No new block')),
                  'no stall message at all -- the alert has been lost');
    });
    test('and it is marked for the operator, not the channel', () => {
        const s = r.messages.find((m) => has(m, 'No new block'));
        assert.ok(r.opsOnly && r.opsOnly.has(s),
                  'the stall would have been published');
    });

    console.log('\n=== and when blocks come back ===');
    const recovering = { lastHeight: 5000, lastHeightAt: now - 120 * 60000,
                         lastHeartbeatAt: now, stallAnnounced: true,
                         milestonesSeen: [] };
    const r2 = A.applyBanner(await A.tick(cfg, rpc(5001), recovering, () => {}));
    test('the recovery is produced', () => {
        assert.ok(r2.messages.some((m) => has(m, 'arriving again')));
    });
    test('and it is the operator\'s too -- a recovery for a stall nobody heard', () => {
        const rec = r2.messages.find((m) => has(m, 'arriving again'));
        assert.ok(r2.opsOnly && r2.opsOnly.has(rec));
    });

    console.log('\n=== the daily heartbeat is still public ===');
    // The daily post goes out at a fixed UTC hour, so a test that hardcodes
    // one passes or fails depending on what time of day it is run. The first
    // version of this fixed it at 12:00 and failed every morning before noon,
    // reporting that the heartbeat had "stopped being produced" when nothing
    // was wrong. The hour is taken from the clock instead, and set to one that
    // has already passed.
    const hourNow = new Date(now).getUTCHours();
    const cfgHb = { ...cfg, heartbeatHourUtc: hourNow };
    const dueAt = Date.UTC(new Date(now).getUTCFullYear(),
                           new Date(now).getUTCMonth(),
                           new Date(now).getUTCDate(), hourNow, 0, 0);
    const due = { lastHeight: 5001, lastHeightAt: now,
                  lastHeartbeatAt: dueAt - 3600000,   // before today's slot
                  stallAnnounced: false, milestonesSeen: [] };
    const r3 = A.applyBanner(await A.tick(cfgHb, rpc(5002), due, () => {}));
    test('the heartbeat is produced', () => {
        assert.ok(r3.messages.some((m) => has(m, 'WAM Network')),
                  'the daily post has stopped being produced');
    });
    test('and it is NOT operator-only', () => {
        const hb = r3.messages.find((m) => has(m, 'WAM Network'));
        assert.ok(!(r3.opsOnly && r3.opsOnly.has(hb)),
                  'the daily post stopped being public');
    });

    console.log(`\n  ${passed} passed, ${failed} failed\n`);
    process.exit(failed ? 1 : 0);
})();

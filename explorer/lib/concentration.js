'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// Who is writing this chain?
//
// Mainnet opened at 00:00 UTC on 2026-09-15. By 00:19 one payout address had
// found 77 of the first 79 blocks -- 97.5% -- and the first people to notice
// were miners who had won nothing, in a chat, at half past two in the
// morning. They concluded the coin was rigged and left. The number that would
// have explained it was published nowhere: not on this explorer, not on the
// ops panel, not in any of the fifty-four launch checks.
//
// So it is published here, permanently, high or low. A reader should never
// have to take our word for how concentrated the hash rate is, and a miner
// deciding which pool to point at should be able to see which pool needs
// them. Concentration is fixed by miners choosing, and by nothing else, so
// the number has to be in front of the people doing the choosing.
//
// WHAT IS COUNTED
//
// The largest output of each coinbase. That is always the miner's: the
// treasury takes 5% of the subsidy by consensus, and the miner takes the
// other 95% plus every fee in the block, so no halving or fee spike can swap
// them round.
//
// One address is not one person. A pool pays its own address and then
// distributes, so the COINS spread out while the HASH RATE stays under one
// operator's hand -- and it is the operator's hand that decides whether the
// chain gets rewritten. That is why this counts addresses and says plainly
// that it counts addresses.
// ---------------------------------------------------------------------------

// How many blocks back the published share is measured over. 50 is about an
// hour at the 120-second target: long enough that one lucky pool does not
// look like a majority, short enough that a real shift shows the same day.
const WINDOW = 50;

// And the long one, because the short one is not the number the project's own
// public condition is written against.
//
// The founder published: no application to any exchange while one finder is
// above 50%, and a target of no finder above 35% OF BLOCKS OVER SEVEN DAYS.
// This module published 48 blocks -- an hour and a half. Within one day that
// short window read 100% and then 54%, while the share over the whole chain
// moved from 97% to 72%. A reader shown only the short figure gets a picture
// worse than the truth in one direction and better in the other, and cannot
// tell which.
//
// 5040 blocks is seven days at the 120-second target. On a chain younger than
// that it covers every block there has ever been, which is what makes it the
// honest denominator today.
const LONG_WINDOW = 5040;

// Heights fetched per refresh. The explorer answers page loads on the same
// event loop, and a cold start asking for fifty blocks at once is a page that
// hangs. It fills in over a few cycles instead.
//
// The long window needs a bigger bite or it would take hours to fill: at 12 a
// cycle, 5040 blocks is 420 cycles. Blocks on this chain carry one
// transaction, so the cost is a round trip rather than parsing.
const MAX_FETCH_PER_CYCLE = 12;
const MAX_BACKFILL_PER_CYCLE = 250;

class Concentration {
    constructor(log) {
        this.log = log;
        this.finders = new Map();      // height -> payout address
        this.tip = 0;
    }

    /**
     * Fetch any heights in the window we have not seen. Cheap after the first
     * pass: only new blocks are unknown.
     */
    async update(rpc, tipHeight) {
        this.tip = tipHeight;
        let fetched = 0;

        // The recent window first and always: it is what a miner refreshing
        // the page is looking at. Only once it is complete does the long one
        // get the rest of this cycle's budget.
        const recentComplete = this._complete(tipHeight, WINDOW);
        const budget = recentComplete ? MAX_BACKFILL_PER_CYCLE : MAX_FETCH_PER_CYCLE;
        const depth = recentComplete ? LONG_WINDOW : WINDOW;

        for (let h = tipHeight; h > tipHeight - depth && h >= 1; h--) {
            if (this.finders.has(h)) continue;
            if (fetched >= budget) break;
            try {
                const hash = await rpc.call('getblockhash', [h]);
                const block = await rpc.call('getblock', [hash, 2]);
                const outs = ((block.tx || [])[0] || {}).vout || [];
                if (!outs.length) continue;
                const biggest = outs.reduce((a, b) => (b.value > a.value ? b : a));
                const addr = (biggest.scriptPubKey || {}).address;
                if (addr) this.finders.set(h, addr);
                fetched++;
            } catch (err) {
                // A height we cannot read is left out of the denominator, not
                // guessed at. The snapshot says how many it actually read.
                this.log.debug(`concentration: block ${h}: ${err.message}`);
            }
        }

        // Anything below the LONG window is no longer part of any answer.
        // Blocks near the tip can still be reorganised away, so they are
        // re-read.
        for (const h of this.finders.keys()) {
            if (h < tipHeight - LONG_WINDOW || h > tipHeight - 3) this.finders.delete(h);
        }
    }

    /** Have we read every height in the last `depth` blocks? */
    _complete(tipHeight, depth) {
        for (let h = tipHeight - 3; h > tipHeight - depth && h >= 1; h--) {
            if (!this.finders.has(h)) return false;
        }
        return true;
    }

    /** Tally over the last `depth` heights we hold. */
    _tally(depth) {
        const tally = new Map();
        let total = 0;
        for (const [h, addr] of this.finders) {
            if (h <= this.tip - depth) continue;
            tally.set(addr, (tally.get(addr) || 0) + 1);
            total++;
        }
        const ranked = [...tally.entries()].sort((a, b) => b[1] - a[1]);
        return {
            window: depth,
            blocksRead: total,
            distinct: ranked.length,
            topPercent: total ? (100 * ranked[0][1]) / total : null,
            top: ranked.slice(0, 5).map(([addr, n]) => ({
                finder: addr.length > 16 ? `${addr.slice(0, 10)}…${addr.slice(-4)}` : addr,
                blocks: n,
                percent: (100 * n) / total
            }))
        };
    }

    /**
     * {window, blocksRead, distinct, top[], topPercent} -- or blocksRead 0
     * before the first pass has anything, which the page must not draw as 0%.
     */
    snapshot() {
        // The recent window stays at the top level, so nothing that already
        // reads this endpoint breaks. The seven-day figure -- the one the
        // published condition is actually written against -- sits beside it,
        // named, with how much of it has been read so far.
        //
        // Addresses are shortened for the same reason the pool API redacts
        // workers: the question is how concentrated the chain is, not who
        // exactly is mining it, and a published list of miners is a published
        // list of targets.
        const recent = this._tally(WINDOW);
        const long = this._tally(LONG_WINDOW);
        return {
            ...recent,
            sevenDay: {
                ...long,
                complete: this._complete(this.tip, LONG_WINDOW),
                // What the founder committed to in public, so the number and
                // the rule it is judged against are never separated.
                noApplicationAbove: 50,
                targetBelow: 35
            }
        };
    }
}

module.exports = { Concentration, WINDOW };

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

// Heights fetched per refresh. The explorer answers page loads on the same
// event loop, and a cold start asking for fifty blocks at once is a page that
// hangs. It fills in over a few cycles instead.
const MAX_FETCH_PER_CYCLE = 12;

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
        for (let h = tipHeight; h > tipHeight - WINDOW && h >= 1; h--) {
            if (this.finders.has(h)) continue;
            if (fetched >= MAX_FETCH_PER_CYCLE) break;
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

        // Anything below the window is no longer part of the answer. Blocks
        // near the tip can still be reorganised away, so they are re-read.
        for (const h of this.finders.keys()) {
            if (h < tipHeight - WINDOW || h > tipHeight - 3) this.finders.delete(h);
        }
    }

    /**
     * {window, blocksRead, distinct, top[], topPercent} -- or blocksRead 0
     * before the first pass has anything, which the page must not draw as 0%.
     */
    snapshot() {
        const tally = new Map();
        for (const addr of this.finders.values()) {
            tally.set(addr, (tally.get(addr) || 0) + 1);
        }
        const total = this.finders.size;
        const ranked = [...tally.entries()].sort((a, b) => b[1] - a[1]);

        return {
            window: WINDOW,
            blocksRead: total,
            distinct: ranked.length,
            topPercent: total ? (100 * ranked[0][1]) / total : null,
            top: ranked.slice(0, 5).map(([addr, n]) => ({
                // Shortened for the same reason the pool API redacts workers:
                // the question is how concentrated the chain is, not who
                // exactly is mining it, and a published list of miners is a
                // published list of targets.
                finder: addr.length > 16 ? `${addr.slice(0, 10)}…${addr.slice(-4)}` : addr,
                blocks: n,
                percent: (100 * n) / total
            }))
        };
    }
}

module.exports = { Concentration, WINDOW };

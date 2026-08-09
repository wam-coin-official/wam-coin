'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// Variable difficulty.
//
// RandomX hashrates span four orders of magnitude -- a phone at 200 H/s and a
// 64-core server at 30 kH/s may be on the same pool. A fixed share difficulty
// would either drown the pool in shares from the big machine or give the small
// one a share every twenty minutes (and a wildly noisy payout).
//
// The controller targets one share every `targetTime` seconds per connection,
// measured over a sliding window, and only acts when the observed rate has
// drifted outside a tolerance band. Retargeting on every share would chase
// Poisson noise forever.
// ---------------------------------------------------------------------------

class VarDiff {
    /**
     * @param {object} cfg
     *   targetTime      seconds between shares to aim for (default 15)
     *   retargetTime    seconds between adjustments      (default 90)
     *   variancePercent tolerance band around targetTime (default 30)
     *   minDiff/maxDiff clamps
     */
    constructor(cfg = {}) {
        this.targetTime = cfg.targetTime || 15;
        this.retargetTime = cfg.retargetTime || 90;
        this.variance = (cfg.variancePercent || 30) / 100;
        this.minDiff = cfg.minDiff || 0.05;
        this.maxDiff = cfg.maxDiff || 2000000;
        this.maxJump = cfg.maxJump || 4;   // never move more than 4x at once

        this.bufferSize = Math.max(4, Math.round(this.retargetTime / this.targetTime * 4));
        this.tMin = this.targetTime * (1 - this.variance);
        this.tMax = this.targetTime * (1 + this.variance);
    }

    /** Per-connection state. */
    createState(startDiff) {
        const now = Date.now() / 1000;
        return {
            difficulty: this._clamp(startDiff),
            lastShare: now,
            lastRetarget: now - this.retargetTime / 2,  // stagger the first retarget
            timeBuffer: []
        };
    }

    /**
     * Feed a share timestamp in. Returns the new difficulty if it changed,
     * otherwise null.
     */
    onShare(state) {
        const now = Date.now() / 1000;
        const sinceLast = now - state.lastShare;
        state.lastShare = now;

        state.timeBuffer.push(sinceLast);
        if (state.timeBuffer.length > this.bufferSize) state.timeBuffer.shift();

        if (now - state.lastRetarget < this.retargetTime) return null;
        if (state.timeBuffer.length < 4) return null;   // not enough evidence yet

        state.lastRetarget = now;

        const avg = state.timeBuffer.reduce((a, b) => a + b, 0) / state.timeBuffer.length;
        if (avg <= 0) return null;
        if (avg >= this.tMin && avg <= this.tMax) return null;   // inside the band

        // Shares arriving twice as fast as wanted -> difficulty should double.
        let factor = avg / this.targetTime;
        factor = Math.max(1 / this.maxJump, Math.min(this.maxJump, factor));

        const next = this._clamp(state.difficulty / factor);
        if (Math.abs(next - state.difficulty) / state.difficulty < 0.05) return null;

        state.difficulty = next;
        state.timeBuffer.length = 0;   // old samples describe the old difficulty
        return next;
    }

    /**
     * A connection that has gone quiet for far longer than the target is
     * probably over-difficultied (or the miner shrank). Called on a timer so
     * that a stalled worker recovers without needing to submit first.
     */
    onIdle(state) {
        const now = Date.now() / 1000;
        const idle = now - state.lastShare;
        if (idle < this.targetTime * 8) return null;

        const next = this._clamp(state.difficulty / 2);
        if (next === state.difficulty) return null;

        state.difficulty = next;
        state.lastRetarget = now;
        state.timeBuffer.length = 0;
        return next;
    }

    _clamp(d) {
        d = Math.min(this.maxDiff, Math.max(this.minDiff, d));
        // Round to 6 significant-ish decimals so the wire value is stable and
        // share accounting is reproducible.
        return Math.round(d * 1000000) / 1000000;
    }
}

module.exports = VarDiff;

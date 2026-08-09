'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  Reward distribution -- PPLNS and PROP
// ===========================================================================
//
//  Deliberately pure functions over plain data: no Redis, no sockets, no
//  clock. Money splitting is the one part of a pool that absolutely must be
//  unit-testable in isolation, and it is tested in test/rewards.test.js.
//
//  ---------------------------------------------------------------------------
//  WHERE THE 5% TREASURY FEE IS ALREADY GONE
//  ---------------------------------------------------------------------------
//  `blockValue` passed in here is BlockTemplate.distributableValue, i.e.
//
//      coinbasevalue - devfee.amount
//
//  The treasury output was paid by the coinbase itself under consensus rule
//  WAM-1. The pool never holds it, never forwards it, and must never count it
//  as revenue. Passing the raw coinbasevalue in here would over-distribute by
//  5% and drain the pool's wallet over time -- so the functions below reject a
//  caller that looks like it made that mistake.
//
//  ---------------------------------------------------------------------------
//  PPLNS vs PROP
//  ---------------------------------------------------------------------------
//  PROP  : split a block among the shares submitted since the last block.
//          Simple and intuitive, but vulnerable to pool hopping -- a miner who
//          only mines the early part of each round earns above their fair
//          share at everyone else's expense.
//
//  PPLNS : split a block among the last N units of difficulty submitted,
//          regardless of round boundaries. Hopping stops being profitable
//          because leaving means forfeiting a share of every block that lands
//          before your work ages out of the window.
//
//  Default is PPLNS with N = 2 x network difficulty, the industry norm.

const { COIN } = require('./constants');

/**
 * Integer-safe proportional split.
 *
 * Every amount is in base units (watoshi). The remainder from integer division
 * is handed to the largest contributor rather than being dropped, so
 * sum(payouts) === amount exactly. Losing dust on every block silently
 * accumulates into a real balance discrepancy over thousands of blocks.
 *
 * @param {Map<string, number>} weights worker -> weight (any positive scale)
 * @param {number} amount base units to split
 * @returns {Map<string, number>} worker -> base units
 */
function splitProportionally(weights, amount) {
    const payouts = new Map();
    if (amount <= 0 || weights.size === 0) return payouts;

    let totalWeight = 0;
    for (const w of weights.values()) {
        if (w > 0) totalWeight += w;
    }
    if (totalWeight <= 0) return payouts;

    let distributed = 0;
    let largestWorker = null;
    let largestWeight = -1;

    for (const [worker, weight] of weights) {
        if (weight <= 0) continue;
        const share = Math.floor((amount * weight) / totalWeight);
        payouts.set(worker, share);
        distributed += share;
        if (weight > largestWeight) {
            largestWeight = weight;
            largestWorker = worker;
        }
    }

    const remainder = amount - distributed;
    if (remainder > 0 && largestWorker !== null) {
        payouts.set(largestWorker, payouts.get(largestWorker) + remainder);
    }

    return payouts;
}

/**
 * Take the most recent shares totalling `windowDifficulty` units of work.
 *
 * @param {Array<{worker,difficulty}>} shares newest first
 * @param {number} windowDifficulty
 * @returns {{weights: Map<string, number>, used: number, covered: number}}
 */
function selectPplnsWindow(shares, windowDifficulty) {
    const weights = new Map();
    let covered = 0;
    let used = 0;

    for (const share of shares) {
        if (covered >= windowDifficulty) break;

        // The share that straddles the window edge counts only for the part
        // that fits, otherwise the window silently grows past N.
        const remaining = windowDifficulty - covered;
        const credited = Math.min(share.difficulty, remaining);

        weights.set(share.worker, (weights.get(share.worker) || 0) + credited);
        covered += credited;
        used++;
    }

    return { weights, used, covered };
}

/**
 * Compute a block's payouts.
 *
 * @param {object} args
 *   mode              'pplns' | 'prop'
 *   blockValue        base units available to miners (devfee already removed)
 *   poolFeePercent    the POOL operator's fee, distinct from the chain's 5%
 *   shares            newest-first [{worker, difficulty}] (pplns)
 *   roundContributions Map worker -> difficulty (prop)
 *   networkDifficulty used to size the pplns window
 *   pplnsMultiplier   window = multiplier x networkDifficulty (default 2)
 *   coinbaseValue     optional: the FULL coinbase, used only for a sanity check
 *   devFeeAmount      optional: the consensus treasury amount, for the same check
 */
function computeBlockRewards(args) {
    const {
        mode = 'pplns',
        blockValue,
        poolFeePercent = 0,
        shares = [],
        roundContributions = new Map(),
        networkDifficulty = 1,
        pplnsMultiplier = 2,
        coinbaseValue = null,
        devFeeAmount = null
    } = args;

    if (!Number.isFinite(blockValue) || blockValue <= 0) {
        throw new Error(`blockValue must be a positive number of base units, got ${blockValue}`);
    }

    // Guard against the single most damaging misuse of this function: handing
    // it the raw coinbasevalue instead of the distributable value.
    if (coinbaseValue !== null && devFeeAmount !== null) {
        const expected = coinbaseValue - devFeeAmount;
        if (blockValue !== expected) {
            throw new Error(
                `blockValue (${blockValue}) does not equal coinbaseValue - devFeeAmount ` +
                `(${coinbaseValue} - ${devFeeAmount} = ${expected}). The consensus treasury ` +
                'output must never be distributed to miners.');
        }
    }

    if (poolFeePercent < 0 || poolFeePercent >= 100) {
        throw new Error(`poolFeePercent must be in [0, 100), got ${poolFeePercent}`);
    }

    // The pool operator's own fee, taken from what is left after the chain's
    // treasury output. These two fees are completely independent.
    const poolFee = Math.floor((blockValue * poolFeePercent * 100) / 10000);
    const minerPot = blockValue - poolFee;

    let weights;
    let windowInfo = null;

    if (mode === 'prop') {
        weights = new Map(roundContributions);
    } else {
        const windowDifficulty = Math.max(1, networkDifficulty * pplnsMultiplier);
        windowInfo = selectPplnsWindow(shares, windowDifficulty);
        weights = windowInfo.weights;

        // Early in a pool's life, or right after a lucky block, there may be
        // less work in the buffer than the window asks for. Paying out only
        // `covered/window` of the block would strand the rest; instead the
        // whole block goes to whoever actually did the work.
        if (weights.size === 0) {
            weights = new Map(roundContributions);
        }
    }

    const payouts = splitProportionally(weights, minerPot);

    const totalPaid = [...payouts.values()].reduce((a, b) => a + b, 0);
    if (totalPaid !== minerPot && payouts.size > 0) {
        throw new Error(`payout accounting error: distributed ${totalPaid} of ${minerPot}`);
    }

    return {
        mode,
        blockValue,
        poolFee,
        minerPot,
        payouts,
        totalPaid,
        workers: payouts.size,
        window: windowInfo
            ? { requested: Math.max(1, networkDifficulty * pplnsMultiplier),
                covered: windowInfo.covered,
                sharesUsed: windowInfo.used }
            : null
    };
}

/**
 * Effective hashrate from a set of shares over a time span.
 *
 * hashrate = (sum of share difficulties x 2^32) / seconds
 *
 * The 2^32 is not a fudge factor: constants.DIFF1 is 2^224 - 1, so a share of
 * difficulty 1 is one hash in 2^256 / 2^224 = 2^32. The two numbers are one
 * decision expressed twice, and they have to move together.
 */
function estimateHashrate(shares, windowSeconds) {
    if (!shares.length || windowSeconds <= 0) return 0;
    const totalDifficulty = shares.reduce((sum, s) => sum + s.difficulty, 0);
    return (totalDifficulty * 4294967296) / windowSeconds;
}

function formatHashrate(hs) {
    const units = ['H/s', 'kH/s', 'MH/s', 'GH/s', 'TH/s'];
    let i = 0;
    while (hs >= 1000 && i < units.length - 1) { hs /= 1000; i++; }
    return `${hs.toFixed(2)} ${units[i]}`;
}

function formatWam(baseUnits) {
    return (baseUnits / COIN).toFixed(8);
}

module.exports = {
    splitProportionally,
    selectPplnsWindow,
    computeBlockRewards,
    estimateHashrate,
    formatHashrate,
    formatWam
};

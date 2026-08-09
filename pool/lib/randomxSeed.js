'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// RandomX seed derivation -- must agree exactly with
// src/wam/crypto/randomx_hash.cpp. If the pool computes a different seed from
// the daemon it will validate every share against the wrong VM and reject
// 100% of legitimate work, so this file is deliberately tiny and directly
// unit-tested (test/seed.test.js).
// ---------------------------------------------------------------------------

const crypto = require('crypto');
const { RANDOMX_EPOCH_BLOCKS, RANDOMX_EPOCH_LAG, RANDOMX_BOOTSTRAP_KEY } = require('./constants');

/**
 * SHA256 of the fixed bootstrap string. Used for every height inside the first
 * epoch, where no block is buried deeply enough to be a safe seed.
 * Mirrors wam::GetRandomXBootstrapSeed().
 */
const BOOTSTRAP_SEED = crypto.createHash('sha256')
    .update(Buffer.from(RANDOMX_BOOTSTRAP_KEY, 'utf8'))
    .digest();

/**
 * Height whose block hash seeds the RandomX key for a block at `height`.
 * Returns 0 to mean "use the bootstrap seed".
 * Mirrors wam::GetRandomXSeedHeight().
 */
function seedHeightFor(height, epochBlocks = RANDOMX_EPOCH_BLOCKS, lag = RANDOMX_EPOCH_LAG) {
    if (height <= lag) return 0;
    const lagged = height - lag;
    return Math.floor(lagged / epochBlocks) * epochBlocks;
}

/**
 * Blocks remaining until the seed changes. Surfaced on the dashboard so an
 * operator can see a dataset rebuild coming instead of being surprised by a
 * hashrate dip.
 */
function blocksUntilNextSeed(height, epochBlocks = RANDOMX_EPOCH_BLOCKS, lag = RANDOMX_EPOCH_LAG) {
    const current = seedHeightFor(height, epochBlocks, lag);
    let next = current + epochBlocks;
    if (current === 0) next = lag + epochBlocks;
    // The seed for height H comes from seedHeightFor(H); find the first future
    // height whose seed differs from the current one.
    let h = height + 1;
    const limit = height + epochBlocks + lag + 2;
    while (h < limit) {
        if (seedHeightFor(h, epochBlocks, lag) !== current) return h - height;
        h++;
    }
    return next - height;
}

/**
 * Resolve the seed for a block at `height`.
 *
 * `getBlockHash` is an async (height) => Buffer(32, little-endian internal
 * order) supplied by the daemon layer. The bootstrap case never calls it.
 */
async function resolveSeed(height, getBlockHash, epochBlocks, lag) {
    const seedHeight = seedHeightFor(height, epochBlocks, lag);
    if (seedHeight === 0) return { seed: BOOTSTRAP_SEED, seedHeight: 0, bootstrap: true };

    const hash = await getBlockHash(seedHeight);
    if (!Buffer.isBuffer(hash) || hash.length !== 32) {
        throw new Error(`daemon returned a malformed block hash for seed height ${seedHeight}`);
    }
    return { seed: hash, seedHeight, bootstrap: false };
}

module.exports = { BOOTSTRAP_SEED, seedHeightFor, blocksUntilNextSeed, resolveSeed };

'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  JobManager -- template polling, seed rotation, and share validation
// ===========================================================================

const EventEmitter = require('events');

const BlockTemplate = require('./blockTemplate');
const randomx = require('../native');
const { seedHeightFor, blocksUntilNextSeed } = require('./randomxSeed');
const {
    reverseBuffer, hashToBigIntLE, difficultyToTarget, targetToDifficulty
} = require('./util');
const { HEADER_SIZE, EXTRANONCE2_SIZE } = require('./constants');

/** Reject codes, mirroring the stratum convention used by every miner. */
const REJECT = {
    JOB_NOT_FOUND:   [21, 'job not found or stale'],
    DUPLICATE:       [22, 'duplicate share'],
    LOW_DIFFICULTY:  [23, 'share above target'],
    UNAUTHORIZED:    [24, 'unauthorized worker'],
    NOT_SUBSCRIBED:  [25, 'not subscribed'],
    BAD_NTIME:       [26, 'ntime out of range'],
    BAD_NONCE_SIZE:  [27, 'malformed nonce or extranonce2'],
    INTERNAL:        [20, 'internal error']
};

class JobManager extends EventEmitter {
    constructor(daemon, config, logger) {
        super();
        this.daemon = daemon;
        this.config = config;
        this.log = logger;

        this.currentJob = null;
        this.validJobs = new Map();          // jobId -> BlockTemplate
        this.maxJobHistory = config.maxJobHistory || 4;

        this.extranonce1Counter = 0;
        this.pollTimer = null;
        this.lastTemplateAt = 0;

        this.stats = {
            templates: 0,
            blocksFound: 0,
            seedRotations: 0,
            lastSeedHeight: null
        };
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    async start() {
        randomx.configure({
            // A verification pool stays in LIGHT mode: 256 MiB rather than
            // 2 GiB per live seed. Verifying shares is not throughput-bound.
            fullMemory: this.config.randomxFullMemory === true,
            vmCount: this.config.randomxVmCount || 4,
            maxSeeds: 2
        });

        this.log.info(`RandomX addon self-test: ${randomx.selfTest().slice(0, 16)}...`);

        await this.refreshTemplate(true);

        const interval = this.config.blockRefreshInterval || 1000;
        this.pollTimer = setInterval(() => {
            this.refreshTemplate(false).catch((err) =>
                this.log.error(`template refresh failed: ${err.message}`));
        }, interval);
    }

    stop() {
        if (this.pollTimer) clearInterval(this.pollTimer);
        this.pollTimer = null;
    }

    /** Pool-assigned per-connection extranonce1. */
    nextExtranonce1() {
        const buf = Buffer.allocUnsafe(4);
        buf.writeUInt32BE((++this.extranonce1Counter) >>> 0, 0);
        return buf;
    }

    // -----------------------------------------------------------------------
    // Templates
    // -----------------------------------------------------------------------

    async refreshTemplate(force) {
        const rpc = await this.daemon.getBlockTemplate();

        const isNewBlock = !this.currentJob ||
                           rpc.previousblockhash !== this.currentJob.previousBlockHash;

        // Rebuild on a new tip, when forced, or periodically so that newly
        // arrived transactions (and their fees) reach miners.
        const stale = Date.now() - this.lastTemplateAt >
                      (this.config.jobRebroadcastTimeout || 55) * 1000;

        if (!force && !isNewBlock && !stale) return;

        const template = new BlockTemplate(rpc, {
            poolAddress: this.config.poolAddress,
            netVersions: this.config.netVersions,
            coinbaseSignature: this.config.coinbaseSignature,
            extranonce1Size: 4
        });

        // ---- RandomX seed for this height ---------------------------------
        //
        // Taken from the daemon verbatim, exactly as the treasury amount is.
        // The epoch rule is consensus: get it wrong by one block and every
        // share the pool accepts is invalid, every block it submits comes back
        // 'high-hash', and the miners are the ones who paid for the
        // electricity. Re-deriving it here would mean a second implementation
        // of a consensus rule, in a second language, drifting from the first.
        //
        // The wire value is a uint256 rendered big-endian; RandomX is keyed
        // with the internal bytes, so it has to be reversed.
        const seedHex = rpc.randomx_seedhash;
        if (typeof seedHex !== 'string' || !/^[0-9a-fA-F]{64}$/.test(seedHex)) {
            throw new Error(
                'getblocktemplate did not return a usable `randomx_seedhash`.\n' +
                'This pool only works against a patched wamd. Guessing the RandomX ' +
                'key would make every share it accepts worthless.');
        }

        const seed = reverseBuffer(Buffer.from(seedHex, 'hex'));
        const seedHeight = typeof rpc.randomx_seedheight === 'number'
            ? rpc.randomx_seedheight
            : null;

        template.seedHash = seed;
        template.seedHeight = seedHeight;

        const bootstrap = seedHeight === 0;

        // Cross-check against our own copy of the epoch constants. The daemon
        // wins either way -- this only tells the operator that lib/constants.js
        // has drifted from the chain, which would make the rotation countdown
        // below a lie.
        if (!this._seedRuleWarned && seedHeight !== null) {
            const derived = seedHeightFor(template.height,
                this.config.randomxEpochBlocks, this.config.randomxEpochLag);
            if (derived !== seedHeight) {
                this._seedRuleWarned = true;
                this.log.warn(
                    `this pool would have derived RandomX seed height ${derived} for ` +
                    `block ${template.height}, but the chain says ${seedHeight}. ` +
                    'Using the chain. Check RANDOMX_EPOCH_BLOCKS and RANDOMX_EPOCH_LAG ' +
                    'in lib/constants.js against src/wam/wam-params.h.');
            }
        }

        if (this.stats.lastSeedHeight !== null && this.stats.lastSeedHeight !== seedHeight) {
            this.stats.seedRotations++;
            this.log.warn(
                `RandomX seed rotated: height ${this.stats.lastSeedHeight} -> ${seedHeight}. ` +
                'Miners will rebuild their datasets; expect a brief hashrate dip.');
        }
        this.stats.lastSeedHeight = seedHeight;

        // ---- publish -------------------------------------------------------
        this.currentJob = template;
        this.lastTemplateAt = Date.now();
        this.stats.templates++;

        this.validJobs.set(template.jobId, template);
        while (this.validJobs.size > this.maxJobHistory) {
            this.validJobs.delete(this.validJobs.keys().next().value);
        }

        if (isNewBlock) {
            // A new tip invalidates everything: old jobs build on a dead parent.
            this.validJobs.clear();
            this.validJobs.set(template.jobId, template);
        }

        this.log.info(
            `job ${template.jobId} height=${template.height} ` +
            `txs=${template.transactions.length} ` +
            `reward=${(template.coinbaseValue / 1e8).toFixed(8)} WAM ` +
            `(devfee ${(template.devFeeAmount / 1e8).toFixed(8)}, ` +
            `miners ${(template.distributableValue / 1e8).toFixed(8)}) ` +
            `seed=${bootstrap ? 'bootstrap' : seedHeight} ` +
            `rotate_in=${blocksUntilNextSeed(template.height,
                this.config.randomxEpochBlocks, this.config.randomxEpochLag)}`);

        this.emit('newJob', template, isNewBlock);
    }

    // -----------------------------------------------------------------------
    // Share validation
    // -----------------------------------------------------------------------

    /**
     * Validate one mining.submit.
     *
     * Returns { valid, error, share } where `share` carries everything the
     * accounting layer needs. This function is the pool's security boundary:
     * every field below arrives from an untrusted miner.
     */
    async processShare(submission) {
        const {
            jobId, extranonce1, extranonce2Hex, nTimeHex, nonceHex,
            workerName, difficulty, ipAddress
        } = submission;

        const job = this.validJobs.get(jobId);
        if (!job) return this._reject(REJECT.JOB_NOT_FOUND, workerName);

        // ---- shape checks --------------------------------------------------
        if (typeof extranonce2Hex !== 'string' ||
            extranonce2Hex.length !== EXTRANONCE2_SIZE * 2 ||
            !/^[0-9a-fA-F]+$/.test(extranonce2Hex)) {
            return this._reject(REJECT.BAD_NONCE_SIZE, workerName);
        }
        if (typeof nonceHex !== 'string' || nonceHex.length !== 8 ||
            !/^[0-9a-fA-F]+$/.test(nonceHex)) {
            return this._reject(REJECT.BAD_NONCE_SIZE, workerName);
        }
        if (typeof nTimeHex !== 'string' || nTimeHex.length !== 8 ||
            !/^[0-9a-fA-F]+$/.test(nTimeHex)) {
            return this._reject(REJECT.BAD_NTIME, workerName);
        }

        const nTime = parseInt(nTimeHex, 16);
        const nonce = parseInt(nonceHex, 16);

        // A miner may roll ntime forward, but not backwards past the template
        // and not more than 2 minutes into the future -- beyond that the block
        // would be rejected by peers for a bad timestamp.
        const nowSec = Math.floor(Date.now() / 1000);
        if (nTime < job.curTime || nTime > nowSec + 120) {
            return this._reject(REJECT.BAD_NTIME, workerName);
        }

        // ---- duplicate detection ------------------------------------------
        const e1hex = extranonce1.toString('hex');
        if (!job.registerSubmit(e1hex, extranonce2Hex, nTimeHex, nonceHex)) {
            return this._reject(REJECT.DUPLICATE, workerName);
        }

        // Everything below can reject, and a rejected share must give its claim
        // back -- it was never credited, so nothing needs to remember it, and
        // keeping it would let anyone fill the set for free. `finally` rather
        // than a release call on each path, so a rejection added here later
        // cannot silently reintroduce the leak.
        let credited = false;
        try {
            // ---- rebuild exactly what the miner hashed --------------------
            const extranonce2 = Buffer.from(extranonce2Hex, 'hex');
            const coinbase = job.serializeCoinbase(extranonce1, extranonce2);
            const merkleRoot = job.computeMerkleRoot(coinbase);
            const header = job.serializeHeader(merkleRoot, nTime, nonce);

            if (header.length !== HEADER_SIZE) {
                this.log.error(`built a ${header.length}-byte header; expected ${HEADER_SIZE}`);
                return this._reject(REJECT.INTERNAL, workerName);
            }

            // ---- the expensive part, off the event loop -------------------
            let powHash;
            try {
                powHash = await randomx.hash(job.seedHash, header);
            } catch (err) {
                this.log.error(`RandomX hashing failed: ${err.message}`);
                return this._reject(REJECT.INTERNAL, workerName);
            }

            const hashValue = hashToBigIntLE(powHash);
            const shareTarget = difficultyToTarget(difficulty);
            const shareDiff = targetToDifficulty(hashValue > 0n ? hashValue : 1n);

            // ---- did it solve the block? ----------------------------------
            const isBlockCandidate = hashValue <= job.target;

            if (!isBlockCandidate && hashValue > shareTarget) {
                this.log.debug(
                    `low-difficulty share from ${workerName}: ` +
                    `diff ${shareDiff.toFixed(6)} < required ${difficulty}`);
                return this._reject(REJECT.LOW_DIFFICULTY, workerName, { shareDiff });
            }

            const share = {
                jobId,
                height: job.height,
                worker: workerName,
                ipAddress,
                difficulty,
                shareDiff,
                blockCandidate: isBlockCandidate,
                blockHash: null,
                powHash: powHash.toString('hex'),
                distributableValue: job.distributableValue,
                devFeeAmount: job.devFeeAmount,
                coinbaseValue: job.coinbaseValue,
                time: Date.now()
            };

            if (isBlockCandidate) {
                await this._submitBlock(job, header, coinbase, share);
            }

            // Past this point the share counts, so its claim is kept: it is the
            // only thing standing between a resubmission and a second payment.
            credited = true;
            this.emit('share', share);
            return { valid: true, share };
        } finally {
            if (!credited) {
                job.releaseSubmit(e1hex, extranonce2Hex, nTimeHex, nonceHex);
            }
        }
    }

    async _submitBlock(job, header, coinbase, share) {
        const blockHex = job.serializeBlock(header, coinbase).toString('hex');
        // Block id is the double-SHA256 of the header, NOT the RandomX hash.
        const blockHash = reverseBuffer(require('./util').sha256d(header)).toString('hex');
        share.blockHash = blockHash;

        this.log.info(`*** BLOCK CANDIDATE at height ${job.height} by ${share.worker} ***`);
        this.log.info(`    hash ${blockHash}`);

        let result = await this.daemon.submitBlock(blockHex);

        // A daemon that could not answer has not rejected the block.
        //
        // submitblock reports two very different things down one channel. An
        // RPC-level failure -- r.ok === false -- means the node never looked
        // at the block: it was starting, loading its wallet, or not
        // listening. A string result means it looked and refused. The first
        // is transient and the block is still worth a full reward. The second
        // is final and retrying it is pointless.
        //
        // On 5 September 2026 the node here was restarted to install v0.1.7
        // while a miner was working. Block 5783 was solved inside that
        // window, came back "REJECTED: Loading wallet...", and was thrown
        // away. One second later the daemon logged "recovered". On testnet
        // that cost nothing. On mainnet it is a miner's block reward, and it
        // would have been discarded by us, during a restart we chose, with
        // nothing but a line in a log to say it had happened.
        //
        // Retried inline, before the share is credited, so blockAccepted is
        // final by the time the record is written and nothing downstream has
        // to learn about a late arrival. Five seconds at the very worst, on a
        // path that is only taken when no daemon is answering at all.
        const RETRIES = 5;
        const GAP_MS = 1000;
        for (let attempt = 1; attempt <= RETRIES; attempt++) {
            if (result.accepted) break;
            const noDaemonAnswered = result.results.length > 0
                                  && result.results.every((r) => !r.ok);
            if (!noDaemonAnswered) break;   // it was looked at and refused
            this.log.warn(`block ${job.height}: no daemon could answer ` +
                          `(${result.reasons.join(' | ')}) -- ` +
                          `retrying ${attempt}/${RETRIES}`);
            await new Promise((r) => setTimeout(r, GAP_MS));
            result = await this.daemon.submitBlock(blockHex);
        }

        if (result.accepted) {
            this.stats.blocksFound++;
            share.blockAccepted = true;
            this.log.info(`*** BLOCK ${job.height} ACCEPTED *** ` +
                          `reward ${(job.coinbaseValue / 1e8).toFixed(8)} WAM, ` +
                          `${(job.distributableValue / 1e8).toFixed(8)} WAM to miners, ` +
                          `${(job.devFeeAmount / 1e8).toFixed(8)} WAM to treasury`);
            this.emit('block', share);
            // Get everyone onto the new tip immediately.
            this.refreshTemplate(true).catch(() => {});
        } else {
            share.blockAccepted = false;
            share.rejectReasons = result.reasons;
            this.log.error(`block ${job.height} REJECTED: ${result.reasons.join(' | ')}`);
            this.emit('blockRejected', share);
        }
    }

    _reject([code, message], worker, extra = {}) {
        this.emit('invalidShare', { worker, code, message, ...extra });
        return { valid: false, error: [code, message, null] };
    }

    // -----------------------------------------------------------------------

    getStatus() {
        const job = this.currentJob;
        return {
            ...this.stats,
            currentJob: job ? job.summary() : null,
            validJobs: this.validJobs.size,
            randomx: randomx.stats(),
            nextSeedRotationIn: job
                ? blocksUntilNextSeed(job.height,
                    this.config.randomxEpochBlocks, this.config.randomxEpochLag)
                : null
        };
    }
}

module.exports = JobManager;
module.exports.REJECT = REJECT;

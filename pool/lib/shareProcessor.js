'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  ShareProcessor -- share accounting, block tracking, and payouts
// ===========================================================================
//
//  Storage layout (Redis, all keys prefixed with `coin:`):
//
//    <p>:round            HASH   worker -> difficulty accumulated this round
//    <p>:pplns            LIST   newest-first JSON shares, trimmed to the window
//    <p>:hashrate         ZSET   score = unix seconds, member = JSON share
//    <p>:blocks:pending   HASH   blockHash -> JSON {height, payouts, ...}
//    <p>:blocks:confirmed LIST   newest-first JSON block records
//    <p>:blocks:orphaned  LIST   newest-first JSON block records
//    <p>:balances         HASH   address -> base units owed (matured)
//    <p>:paid             HASH   address -> base units paid all time
//    <p>:payments         LIST   newest-first JSON payment batches
//    <p>:poolfees         STRING base units collected by the operator
//
//  THE CRITICAL ORDERING RULE
//  --------------------------
//  PPLNS payouts are computed AT THE MOMENT THE BLOCK IS FOUND and frozen into
//  the pending-block record. They are NOT recomputed at maturity. Recomputing
//  100 blocks later would use a share buffer that has completely turned over,
//  paying people who were not mining when the block was won -- which is both
//  unfair and, once miners notice, fatal to the pool's reputation.
//
//  Balances are only credited once a block has COINBASE_MATURITY confirmations
//  AND is still on the main chain. An orphaned block pays nobody; its record
//  moves to <p>:blocks:orphaned so the loss is auditable rather than silent.

const EventEmitter = require('events');

const { computeBlockRewards, estimateHashrate } = require('./rewards');
const { COIN, COINBASE_MATURITY } = require('./constants');

class ShareProcessor extends EventEmitter {
    /**
     * @param {import('ioredis')} redis
     * @param {import('./daemon')} daemon
     */
    constructor(redis, daemon, config, logger) {
        super();
        this.redis = redis;
        this.daemon = daemon;
        this.config = config;
        this.log = logger;

        this.prefix = config.redisPrefix || 'wam';
        this.mode = (config.rewardMode || 'pplns').toLowerCase();
        this.poolFeePercent = config.poolFeePercent || 1;
        this.pplnsMultiplier = config.pplnsMultiplier || 2;
        this.maturity = config.coinbaseMaturity || COINBASE_MATURITY;

        if (!['pplns', 'prop'].includes(this.mode)) {
            throw new Error(`rewardMode must be 'pplns' or 'prop', got '${config.rewardMode}'`);
        }

        this.networkDifficulty = 1;
        this.timers = [];
    }

    k(...parts) { return [this.prefix, ...parts].join(':'); }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    start() {
        this.log.info(`reward mode: ${this.mode.toUpperCase()}` +
            (this.mode === 'pplns' ? ` (window = ${this.pplnsMultiplier}x network difficulty)` : '') +
            `, pool fee ${this.poolFeePercent}%`);
        this.log.info('the chain\'s 5% treasury output is paid by the coinbase itself and is ' +
                      'never part of the miner pot');

        const blockCheck = (this.config.blockCheckIntervalSec || 60) * 1000;
        const payoutCheck = (this.config.paymentIntervalSec || 600) * 1000;
        const pruneCheck = 300 * 1000;

        this.timers.push(setInterval(() => this.checkPendingBlocks()
            .catch((e) => this.log.error(`block check failed: ${e.message}`)), blockCheck));

        this.timers.push(setInterval(() => this.processPayments()
            .catch((e) => this.log.error(`payment run failed: ${e.message}`)), payoutCheck));

        this.timers.push(setInterval(() => this.pruneHashrateWindow()
            .catch(() => {}), pruneCheck));
    }

    stop() {
        for (const t of this.timers) clearInterval(t);
        this.timers = [];
    }

    setNetworkDifficulty(d) {
        if (Number.isFinite(d) && d > 0) this.networkDifficulty = d;
    }

    // -----------------------------------------------------------------------
    // Shares
    // -----------------------------------------------------------------------

    async recordShare(share) {
        const now = Math.floor(Date.now() / 1000);
        const entry = JSON.stringify({
            w: share.worker,
            d: share.difficulty,
            t: now,
            // A unique suffix: ZSET members must be distinct or identical
            // shares would silently overwrite each other in the hashrate window.
            n: `${share.jobId}-${Math.random().toString(36).slice(2, 8)}`
        });

        const windowSize = this._pplnsBufferSize();

        const pipe = this.redis.pipeline();
        pipe.hincrbyfloat(this.k('round'), share.worker, share.difficulty);
        pipe.lpush(this.k('pplns'), entry);
        pipe.ltrim(this.k('pplns'), 0, windowSize - 1);
        pipe.zadd(this.k('hashrate'), now, entry);
        await pipe.exec();
    }

    /**
     * How many share entries to retain.
     *
     * The window is defined in units of difficulty, but Redis trims by count,
     * so we keep a generous multiple of the expected share count and let
     * selectPplnsWindow() do the exact difficulty accounting. Being too
     * generous costs a little memory; being too stingy would silently truncate
     * the window and underpay long-running miners.
     */
    _pplnsBufferSize() {
        const configured = this.config.pplnsMaxShares;
        if (configured) return configured;
        const avgShareDiff = this.config.startDifficulty || 1000;
        const needed = (this.networkDifficulty * this.pplnsMultiplier) / avgShareDiff;
        return Math.max(10000, Math.min(2000000, Math.ceil(needed * 4)));
    }

    async getPplnsShares() {
        const raw = await this.redis.lrange(this.k('pplns'), 0, this._pplnsBufferSize() - 1);
        return raw.map((s) => {
            const o = JSON.parse(s);
            return { worker: o.w, difficulty: o.d, time: o.t };
        });
    }

    async getRoundContributions() {
        const hash = await this.redis.hgetall(this.k('round'));
        const out = new Map();
        for (const [worker, diff] of Object.entries(hash)) {
            const d = parseFloat(diff);
            if (d > 0) out.set(worker, d);
        }
        return out;
    }

    // -----------------------------------------------------------------------
    // Blocks
    // -----------------------------------------------------------------------

    /**
     * Called the instant a block is accepted by the daemon.
     * Freezes the payout table and resets the round.
     */
    async recordBlock(share) {
        const [shares, roundContributions] = await Promise.all([
            this.mode === 'pplns' ? this.getPplnsShares() : Promise.resolve([]),
            this.getRoundContributions()
        ]);

        let rewards;
        try {
            rewards = computeBlockRewards({
                mode: this.mode,
                blockValue: share.distributableValue,
                coinbaseValue: share.coinbaseValue,
                devFeeAmount: share.devFeeAmount,
                poolFeePercent: this.poolFeePercent,
                shares,
                roundContributions,
                networkDifficulty: this.networkDifficulty,
                pplnsMultiplier: this.pplnsMultiplier
            });
        } catch (err) {
            // Never lose a block over an accounting bug: park it for manual
            // review rather than dropping it on the floor.
            this.log.error(`reward computation failed for block ${share.height}: ${err.message}`);
            await this.redis.hset(this.k('blocks:failed'), share.blockHash,
                JSON.stringify({ ...share, error: err.message }));
            return null;
        }

        const record = {
            height: share.height,
            blockHash: share.blockHash,
            finder: share.worker,
            time: Date.now(),
            coinbaseValue: share.coinbaseValue,
            devFeeAmount: share.devFeeAmount,
            distributableValue: share.distributableValue,
            poolFee: rewards.poolFee,
            minerPot: rewards.minerPot,
            payouts: Object.fromEntries(rewards.payouts),
            workers: rewards.workers,
            window: rewards.window,
            mode: this.mode,
            confirmations: 0
        };

        const pipe = this.redis.pipeline();
        pipe.hset(this.k('blocks:pending'), share.blockHash, JSON.stringify(record));
        pipe.del(this.k('round'));           // PROP round closes here
        pipe.incrby(this.k('poolfees'), rewards.poolFee);
        await pipe.exec();

        this.log.info(
            `block ${share.height} recorded: ${(record.minerPot / COIN).toFixed(8)} WAM to ` +
            `${record.workers} workers, ${(record.poolFee / COIN).toFixed(8)} WAM pool fee, ` +
            `${(record.devFeeAmount / COIN).toFixed(8)} WAM treasury (paid by consensus)`);

        this.emit('blockRecorded', record);
        return record;
    }

    /**
     * Move matured blocks into balances and discard orphans.
     */
    async checkPendingBlocks() {
        const pending = await this.redis.hgetall(this.k('blocks:pending'));
        const hashes = Object.keys(pending);
        if (hashes.length === 0) return;

        for (const hash of hashes) {
            let record;
            try {
                record = JSON.parse(pending[hash]);
            } catch {
                await this.redis.hdel(this.k('blocks:pending'), hash);
                continue;
            }

            let block;
            try {
                block = await this.daemon.getBlock(hash, 1);
            } catch (err) {
                // getblock throws "Block not found" for an orphan the node has
                // already discarded -- that is a definitive orphan signal.
                if (/not found/i.test(err.message)) {
                    await this._orphan(hash, record, 'block not found on the node');
                } else {
                    this.log.warn(`could not check block ${record.height}: ${err.message}`);
                }
                continue;
            }

            if (block.confirmations === -1) {
                await this._orphan(hash, record, 'chain reorganisation');
                continue;
            }

            record.confirmations = block.confirmations;

            if (block.confirmations < this.maturity) {
                await this.redis.hset(this.k('blocks:pending'), hash, JSON.stringify(record));
                continue;
            }

            await this._mature(hash, record);
        }
    }

    async _orphan(hash, record, reason) {
        this.log.warn(`block ${record.height} ORPHANED (${reason}); ` +
                      `${(record.minerPot / COIN).toFixed(8)} WAM will not be paid`);

        record.orphanedAt = Date.now();
        record.orphanReason = reason;

        const pipe = this.redis.pipeline();
        pipe.hdel(this.k('blocks:pending'), hash);
        pipe.lpush(this.k('blocks:orphaned'), JSON.stringify(record));
        pipe.ltrim(this.k('blocks:orphaned'), 0, 999);
        pipe.decrby(this.k('poolfees'), record.poolFee);
        await pipe.exec();

        this.emit('blockOrphaned', record);
    }

    async _mature(hash, record) {
        const pipe = this.redis.pipeline();

        for (const [worker, amount] of Object.entries(record.payouts)) {
            if (amount <= 0) continue;
            // Workers authorize as "<address>.<label>"; balances are per address.
            const address = worker.split('.')[0];
            pipe.hincrby(this.k('balances'), address, amount);
        }

        record.maturedAt = Date.now();
        pipe.hdel(this.k('blocks:pending'), hash);
        pipe.lpush(this.k('blocks:confirmed'), JSON.stringify(record));
        pipe.ltrim(this.k('blocks:confirmed'), 0, 4999);

        await pipe.exec();

        this.log.info(`block ${record.height} matured (${record.confirmations} confs); ` +
                      `${(record.minerPot / COIN).toFixed(8)} WAM credited to ` +
                      `${record.workers} miners`);
        this.emit('blockMatured', record);
    }

    // -----------------------------------------------------------------------
    // Payments
    // -----------------------------------------------------------------------

    async processPayments() {
        const threshold = Math.round((this.config.minimumPayoutWam || 1) * COIN);
        const balances = await this.redis.hgetall(this.k('balances'));

        const due = Object.entries(balances)
            .map(([address, amount]) => [address, parseInt(amount, 10)])
            .filter(([, amount]) => amount >= threshold);

        if (due.length === 0) return;

        // ---- cap the batch --------------------------------------------------
        //
        // One sendmany per payment round works until the pool succeeds. A
        // transaction carrying thousands of outputs stops being relayed: a
        // P2WPKH output is 31 bytes plus overhead, so somewhere around three
        // thousand miners the transaction passes 100 kB and every node drops
        // it as non-standard. The pool would then retry the same oversized
        // payment every round, forever, and nobody would be paid at all.
        //
        // Whatever does not fit stays in `balances` untouched and goes out in
        // the next round. Raised by an external reviewer, 2026-08-09.
        const maxRecipients = this.config.maxPaymentRecipients || 200;
        const maxPerBatch = Math.round(
            (this.config.maxWamPerPaymentBatch || 100000) * COIN);

        const batch = [];
        let batchTotal = 0;

        for (const [address, amount] of due) {
            if (batch.length >= maxRecipients) break;

            if (batchTotal + amount > maxPerBatch) {
                // A single balance larger than the whole cap would otherwise
                // block the queue for ever. Pay what the cap allows; the
                // remainder is still owed and still recorded.
                if (batch.length === 0) {
                    this.log.warn(
                        `${address} is owed ${(amount / COIN).toFixed(8)} WAM, more than the ` +
                        `${(maxPerBatch / COIN).toFixed(8)} WAM batch cap. Paying the cap now, ` +
                        'the rest next round.');
                    batch.push([address, maxPerBatch]);
                    batchTotal = maxPerBatch;
                }
                break;
            }

            batch.push([address, amount]);
            batchTotal += amount;
        }

        if (batch.length < due.length) {
            this.log.info(
                `payment split: ${batch.length} of ${due.length} miners this round ` +
                `(${(batchTotal / COIN).toFixed(8)} WAM). The rest keep their balances ` +
                'and are paid next run.');
        }

        // Never attempt a payment the wallet cannot cover: a partially failed
        // sendmany is far harder to reconcile than a postponed one.
        const walletBalance = Math.round((await this.daemon.getBalance()) * COIN);
        const reserve = Math.round((this.config.txFeeReserveWam || 0.01) * COIN);

        if (walletBalance < batchTotal + reserve) {
            this.log.warn(
                `payment run postponed: wallet holds ${(walletBalance / COIN).toFixed(8)} WAM ` +
                `but ${((batchTotal + reserve) / COIN).toFixed(8)} WAM is due in this batch. ` +
                'This is normal if blocks are still maturing.');
            return;
        }

        const sendMany = {};
        for (const [address, amount] of batch) {
            sendMany[address] = Number((amount / COIN).toFixed(8));
        }

        this.log.info(`paying ${batch.length} miners a total of ` +
                      `${(batchTotal / COIN).toFixed(8)} WAM`);

        let txid;
        try {
            txid = await this.daemon.cmd('sendmany', ['', sendMany]);
        } catch (err) {
            this.log.error(`sendmany failed, balances left untouched: ${err.message}`);
            return;
        }

        // Only now is it safe to clear balances. Doing it before the RPC
        // returned would lose every miner's money if the call failed.
        // Deduct exactly what was sent, not what was owed. For a balance that
        // hit the cap those differ, and the difference is the miner's money.
        const pipe = this.redis.pipeline();
        for (const [address, amount] of batch) {
            pipe.hincrby(this.k('balances'), address, -amount);
            pipe.hincrby(this.k('paid'), address, amount);
        }
        pipe.lpush(this.k('payments'), JSON.stringify({
            txid, time: Date.now(), total: batchTotal, recipients: batch.length,
            payouts: Object.fromEntries(batch)
        }));
        pipe.ltrim(this.k('payments'), 0, 999);
        await pipe.exec();

        this.log.info(`payment sent, txid ${txid}`);
        this.emit('payment', {
            txid,
            total: batchTotal,
            recipients: batch.length,
            deferred: due.length - batch.length
        });
    }

    // -----------------------------------------------------------------------
    // Stats
    // -----------------------------------------------------------------------

    async pruneHashrateWindow() {
        const cutoff = Math.floor(Date.now() / 1000) - (this.config.hashrateWindowSec || 600);
        await this.redis.zremrangebyscore(this.k('hashrate'), '-inf', cutoff);
    }

    async getHashrateStats() {
        const windowSec = this.config.hashrateWindowSec || 600;
        const since = Math.floor(Date.now() / 1000) - windowSec;
        const raw = await this.redis.zrangebyscore(this.k('hashrate'), since, '+inf');

        const shares = raw.map((s) => JSON.parse(s));
        const perWorker = new Map();

        for (const s of shares) {
            const list = perWorker.get(s.w) || [];
            list.push({ difficulty: s.d });
            perWorker.set(s.w, list);
        }

        const workers = {};
        for (const [worker, list] of perWorker) {
            workers[worker] = {
                hashrate: estimateHashrate(list, windowSec),
                shares: list.length
            };
        }

        return {
            windowSeconds: windowSec,
            poolHashrate: estimateHashrate(shares.map((s) => ({ difficulty: s.d })), windowSec),
            totalShares: shares.length,
            workers
        };
    }

    async getPoolStats() {
        const [confirmed, orphaned, payments, balances, paid, fees, pendingRaw] =
            await Promise.all([
                this.redis.lrange(this.k('blocks:confirmed'), 0, 49),
                this.redis.lrange(this.k('blocks:orphaned'), 0, 24),
                this.redis.lrange(this.k('payments'), 0, 24),
                this.redis.hgetall(this.k('balances')),
                this.redis.hgetall(this.k('paid')),
                this.redis.get(this.k('poolfees')),
                this.redis.hgetall(this.k('blocks:pending'))
            ]);

        const parse = (arr) => arr.map((s) => { try { return JSON.parse(s); } catch { return null; } })
                                  .filter(Boolean);

        const confirmedBlocks = parse(confirmed);
        const pendingBlocks = parse(Object.values(pendingRaw));

        const totalPaid = Object.values(paid).reduce((a, b) => a + parseInt(b, 10), 0);
        const totalOwed = Object.values(balances).reduce((a, b) => a + parseInt(b, 10), 0);
        const treasuryPaid = [...confirmedBlocks, ...pendingBlocks]
            .reduce((a, b) => a + (b.devFeeAmount || 0), 0);

        return {
            rewardMode: this.mode,
            poolFeePercent: this.poolFeePercent,
            chainDevFeePercent: 5,
            blocksConfirmed: confirmedBlocks.length,
            blocksPending: pendingBlocks.length,
            blocksOrphaned: parse(orphaned).length,
            totalPaid,
            totalOwed,
            poolFeesCollected: parseInt(fees || '0', 10),
            treasuryPaidByConsensus: treasuryPaid,
            recentBlocks: confirmedBlocks.slice(0, 25).map(summariseBlock),
            pendingBlocks: pendingBlocks.map(summariseBlock),
            orphanedBlocks: parse(orphaned).map(summariseBlock),
            recentPayments: parse(payments)
        };
    }

    async getMinerStats(address) {
        const [balance, paid, hashrate] = await Promise.all([
            this.redis.hget(this.k('balances'), address),
            this.redis.hget(this.k('paid'), address),
            this.getHashrateStats()
        ]);

        const workers = {};
        let total = 0;
        for (const [worker, stats] of Object.entries(hashrate.workers)) {
            if (worker.split('.')[0] !== address) continue;
            workers[worker] = stats;
            total += stats.hashrate;
        }

        return {
            address,
            balance: parseInt(balance || '0', 10),
            totalPaid: parseInt(paid || '0', 10),
            hashrate: total,
            workers
        };
    }
}

function summariseBlock(b) {
    return {
        height: b.height,
        hash: b.blockHash,
        finder: b.finder,
        time: b.time,
        confirmations: b.confirmations,
        coinbaseValue: b.coinbaseValue,
        devFeeAmount: b.devFeeAmount,
        minerPot: b.minerPot,
        poolFee: b.poolFee,
        workers: b.workers,
        orphanReason: b.orphanReason || null
    };
}

module.exports = ShareProcessor;

'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  BlockTemplate -- turns a getblocktemplate reply into a mineable stratum job
// ===========================================================================
//
//  THE DEV FEE, AND WHY THE POOL CANNOT GET IT WRONG
//  -------------------------------------------------
//  Consensus rule WAM-1 (src/wam/consensus/devfee.cpp) rejects any block whose
//  coinbase does not pay >= 5% of the subsidy to the treasury script. So the
//  pool has exactly one job here: put that output in, and then distribute only
//  what is left.
//
//  The patched wamd reports the exact required amount in the `devfee` field of
//  getblocktemplate. We use that number verbatim rather than recomputing 5%
//  locally, because recomputing means duplicating the halving schedule in a
//  second language and being wrong about it at some future halving.
//
//  If the field is absent the daemon is not a WAM daemon (or is unpatched) and
//  we refuse to build a template at all. Mining blocks that consensus will
//  reject is the single most expensive bug a pool can have.
//
//  What miners get paid on is therefore:
//      distributable = coinbasevalue - devfee.amount
//  and that -- not the raw block reward -- is what flows into PPLNS.

const {
    sha256d, reverseBuffer, reverseByteOrder, varIntBuffer, pushData,
    serializeHeight, packUInt32LE, packInt32LE, packInt64LE,
    addressToScript, buildMerkleBranch, applyMerkleBranch, bitsToTarget
} = require('./util');

const { EXTRANONCE2_SIZE, DEVFEE_PERCENT } = require('./constants');

let jobCounter = 0;

class BlockTemplate {
    /**
     * @param {object} rpcTemplate  raw getblocktemplate result
     * @param {object} opts {poolAddress, netVersions, coinbaseSignature, network}
     */
    constructor(rpcTemplate, opts) {
        this.rpc = rpcTemplate;
        this.opts = opts;

        this.jobId = (++jobCounter).toString(16);
        this.height = rpcTemplate.height;
        this.version = rpcTemplate.version;
        this.curTime = rpcTemplate.curtime;
        this.bits = rpcTemplate.bits;                       // hex string
        this.nBits = parseInt(rpcTemplate.bits, 16);
        this.target = rpcTemplate.target
            ? BigInt('0x' + rpcTemplate.target)
            : bitsToTarget(this.nBits);
        this.previousBlockHash = rpcTemplate.previousblockhash;
        this.transactions = rpcTemplate.transactions || [];
        this.coinbaseValue = rpcTemplate.coinbasevalue;

        this.submits = new Set();   // duplicate-share detection, per job

        this._validateDevFee();
        this._buildCoinbase();
        this._buildMerkleBranch();

        this.seedHash = null;       // filled in by JobManager (async lookup)
        this.seedHeight = null;
    }

    // -----------------------------------------------------------------------

    _validateDevFee() {
        const df = this.rpc.devfee;

        if (!df || typeof df.amount !== 'number' || !df.script) {
            throw new Error(
                'getblocktemplate did not return a `devfee` field.\n' +
                'This pool only works against a patched wamd (see ' +
                'patches/0005-gbt-devfee-field.patch). Building a coinbase without ' +
                'the treasury output would produce blocks that consensus rejects ' +
                'with bad-cb-devfee-amount, wasting every share submitted to it.');
        }

        if (df.amount < 0 || df.amount > this.coinbaseValue) {
            throw new Error(`daemon reported a nonsensical devfee amount ${df.amount} ` +
                            `against coinbasevalue ${this.coinbaseValue}`);
        }

        // ---- cross-check the two numbers against each other -----------------
        //
        // BIP22 says coinbasevalue is the TOTAL the coinbase may claim, fees
        // included, and the treasury is paid out of it. If a daemon instead
        // reports the miner's share -- which is what ours did once WAM-014 gave
        // the coinbase a second output -- then subtracting the treasury here is
        // subtracting it twice, and the pool simply never claims 5% of any block
        // it mines. Nothing errors. Miners are underpaid forever, by a chain
        // that looks healthy from every angle.
        //
        // The invariant that catches it: the treasury is a fixed percentage of
        // the SUBSIDY, and the subsidy is coinbasevalue minus the fees, which
        // every template transaction reports individually. Deriving the subsidy
        // this way rather than from the halving schedule keeps the check valid
        // on regtest and testnet, where the interval differs.
        if (df.amount > 0) {
            const percent = typeof df.percent === 'number' ? df.percent : DEVFEE_PERCENT;

            if (percent !== DEVFEE_PERCENT) {
                throw new Error(
                    `the chain says the treasury fee is ${percent}% but this pool was ` +
                    `built for ${DEVFEE_PERCENT}%. Update lib/constants.js to match ` +
                    'src/wam/wam-params.h, or run a daemon that matches this pool.');
            }

            // A template transaction with an unknown fee makes the sum useless.
            const feesKnown = this.transactions.every((tx) => typeof tx.fee === 'number' &&
                                                              tx.fee >= 0);
            if (feesKnown) {
                const totalFees = this.transactions.reduce((sum, tx) => sum + tx.fee, 0);
                const subsidy   = this.coinbaseValue - totalFees;
                const expected  = Math.floor((subsidy * percent) / 100);

                if (df.amount !== expected) {
                    throw new Error(
                        `the treasury output does not match the block reward.\n` +
                        `  coinbasevalue  ${this.coinbaseValue} sat\n` +
                        `  fees           ${totalFees} sat\n` +
                        `  => subsidy     ${subsidy} sat\n` +
                        `  ${percent}% of that   ${expected} sat\n` +
                        `  daemon says    ${df.amount} sat\n` +
                        'These have to agree. The usual cause is a daemon reporting ' +
                        'coinbasevalue net of the treasury instead of the BIP22 total, ' +
                        'which would make this pool destroy the difference in every ' +
                        'block it mined. Refusing to build a template.');
                }
            }
        }

        this.devFeeAmount = df.amount;
        this.devFeeScript = Buffer.from(df.script, 'hex');
        this.devFeeAddress = df.address || null;

        // What the pool actually has to share out among miners.
        this.distributableValue = this.coinbaseValue - this.devFeeAmount;

        if (this.distributableValue <= 0) {
            throw new Error('nothing left to distribute after the treasury output');
        }
    }

    /**
     * Split the coinbase transaction at the extranonce insertion point.
     *
     * Stratum sends miners coinb1 and coinb2; the miner splices
     * extranonce1 (pool-assigned, per connection) and extranonce2
     * (miner-chosen) between them. That is what gives each miner a private
     * search space without the pool having to hand out distinct jobs.
     */
    _buildCoinbase() {
        const { poolAddress, netVersions, coinbaseSignature } = this.opts;

        // ---- scriptSig -----------------------------------------------------
        // BIP34 requires the height as the first push. The signature is a
        // vanity string; the extranonce placeholder follows it.
        const heightPush = serializeHeight(this.height);
        const sigBuf = Buffer.from(coinbaseSignature || '/WAM/', 'utf8');
        const sigPush = pushData(sigBuf);

        const extranonceSize = this.opts.extranonce1Size + EXTRANONCE2_SIZE;
        const scriptSigLength = heightPush.length + sigPush.length + extranonceSize;

        if (scriptSigLength > 100) {
            throw new Error(`coinbase scriptSig would be ${scriptSigLength} bytes; ` +
                            'consensus caps it at 100. Shorten coinbaseSignature.');
        }

        // ---- outputs -------------------------------------------------------
        const outputs = [];

        // 1. Treasury. Placed first so it is trivially auditable by anyone
        //    decoding the coinbase in a block explorer.
        outputs.push(Buffer.concat([
            packInt64LE(this.devFeeAmount),
            varIntBuffer(this.devFeeScript.length),
            this.devFeeScript
        ]));

        // 2. The pool's own address -- everything that is not the treasury.
        const poolScript = addressToScript(poolAddress, netVersions);
        outputs.push(Buffer.concat([
            packInt64LE(this.distributableValue),
            varIntBuffer(poolScript.length),
            poolScript
        ]));

        // 3. SegWit commitment. Taken verbatim from the daemon: recomputing the
        //    witness merkle root here would duplicate consensus logic for no
        //    benefit.
        if (this.rpc.default_witness_commitment) {
            const wc = Buffer.from(this.rpc.default_witness_commitment, 'hex');
            outputs.push(Buffer.concat([
                packInt64LE(0),
                varIntBuffer(wc.length),
                wc
            ]));
            this.hasWitnessCommitment = true;
        }

        const outputBuffer = Buffer.concat([
            varIntBuffer(outputs.length),
            Buffer.concat(outputs)
        ]);

        // ---- coinb1 : everything up to the extranonce ----------------------
        this.coinbase1 = Buffer.concat([
            packInt32LE(this.rpc.txversion || 1),
            Buffer.from([0x01]),                       // vin count
            Buffer.alloc(32),                          // prevout.hash = null
            Buffer.from('ffffffff', 'hex'),            // prevout.n
            varIntBuffer(scriptSigLength),
            heightPush,
            sigPush
            // extranonce1 + extranonce2 are spliced in by the miner here
        ]);

        // ---- coinb2 : everything after it ----------------------------------
        this.coinbase2 = Buffer.concat([
            Buffer.from('ffffffff', 'hex'),            // nSequence
            outputBuffer,
            Buffer.alloc(4)                            // nLockTime
        ]);
    }

    _buildMerkleBranch() {
        // GBT gives txids big-endian; the merkle tree works little-endian.
        const hashes = this.transactions.map((tx) =>
            reverseBuffer(Buffer.from(tx.txid || tx.hash, 'hex')));
        this.merkleBranch = buildMerkleBranch(hashes);
        this.merkleBranchHex = this.merkleBranch.map((b) => b.toString('hex'));
    }

    // -----------------------------------------------------------------------
    // Share reconstruction
    // -----------------------------------------------------------------------

    serializeCoinbase(extranonce1, extranonce2) {
        return Buffer.concat([this.coinbase1, extranonce1, extranonce2, this.coinbase2]);
    }

    /** The 80-byte header a miner actually hashed. */
    serializeHeader(merkleRoot, nTime, nonce) {
        return Buffer.concat([
            packInt32LE(this.version),
            reverseBuffer(Buffer.from(this.previousBlockHash, 'hex')),
            merkleRoot,
            packUInt32LE(nTime),
            packUInt32LE(this.nBits),
            packUInt32LE(nonce)
        ]);
    }

    /** Full block for submitblock: header + all transactions. */
    serializeBlock(header, coinbaseBuffer) {
        return Buffer.concat([
            header,
            varIntBuffer(this.transactions.length + 1),
            coinbaseBuffer,
            ...this.transactions.map((tx) => Buffer.from(tx.data, 'hex'))
        ]);
    }

    computeMerkleRoot(coinbaseBuffer) {
        return applyMerkleBranch(sha256d(coinbaseBuffer), this.merkleBranch);
    }

    /** Reject a share we have already accounted for. Returns false on duplicate. */
    registerSubmit(extranonce1, extranonce2, nTime, nonce) {
        const key = `${extranonce1}:${extranonce2}:${nTime}:${nonce}`;
        if (this.submits.has(key)) return false;
        this.submits.add(key);
        return true;
    }

    // -----------------------------------------------------------------------

    /** mining.notify parameters. The 10th element is a WAM extension. */
    getJobParams(cleanJobs) {
        return [
            this.jobId,
            reverseByteOrder(Buffer.from(this.previousBlockHash, 'hex')).toString('hex'),
            this.coinbase1.toString('hex'),
            this.coinbase2.toString('hex'),
            this.merkleBranchHex,
            packInt32LE(this.version).reverse().toString('hex'),
            this.bits,
            packUInt32LE(this.curTime).reverse().toString('hex'),
            cleanJobs === true,
            // --- WAM extension -------------------------------------------
            // The RandomX key for this height. Miners must reinitialise their
            // VM whenever this value changes. Standard SHA256 stratum clients
            // ignore trailing parameters, so this stays wire-compatible.
            this.seedHash ? this.seedHash.toString('hex') : null
        ];
    }

    summary() {
        return {
            jobId: this.jobId,
            height: this.height,
            transactions: this.transactions.length,
            coinbaseValue: this.coinbaseValue,
            devFeeAmount: this.devFeeAmount,
            distributableValue: this.distributableValue,
            bits: this.bits,
            seedHeight: this.seedHeight
        };
    }
}

module.exports = BlockTemplate;

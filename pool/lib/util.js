'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// Bitcoin serialization helpers. Every function here has a counterpart in the
// C++ node or in genesis/genesis_generator.py; where that is the case the
// counterpart is named in the comment so a reviewer can diff the two.

const crypto = require('crypto');
const { COIN, DIFF1 } = require('./constants');

const B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

function sha256(buf) {
    return crypto.createHash('sha256').update(buf).digest();
}

function sha256d(buf) {
    return sha256(sha256(buf));
}

/** RIPEMD160(SHA256(x)) -- Bitcoin's Hash160. */
function hash160(buf) {
    return crypto.createHash('ripemd160').update(sha256(buf)).digest();
}

/** Reverse byte order. Used constantly because Bitcoin displays hashes big-endian
 *  but serializes them little-endian. */
function reverseBuffer(buf) {
    const out = Buffer.allocUnsafe(buf.length);
    for (let i = 0; i < buf.length; i++) out[i] = buf[buf.length - 1 - i];
    return out;
}

/** Reverse each 4-byte word in place -- the transformation stratum applies to
 *  prevhash before putting it on the wire. */
function reverseByteOrder(buf) {
    const out = Buffer.allocUnsafe(buf.length);
    for (let i = 0; i < buf.length / 4; i++) {
        out.writeUInt32BE(buf.readUInt32LE(i * 4), i * 4);
    }
    return out;
}

/** CompactSize / varint, matching genesis_generator.varint(). */
function varIntBuffer(n) {
    if (n < 0xfd) return Buffer.from([n]);
    if (n <= 0xffff) {
        const b = Buffer.allocUnsafe(3); b[0] = 0xfd; b.writeUInt16LE(n, 1); return b;
    }
    if (n <= 0xffffffff) {
        const b = Buffer.allocUnsafe(5); b[0] = 0xfe; b.writeUInt32LE(n, 1); return b;
    }
    const b = Buffer.allocUnsafe(9);
    b[0] = 0xff;
    b.writeBigUInt64LE(BigInt(n), 1);
    return b;
}

/** Script push, matching genesis_generator.push_data(). */
function pushData(buf) {
    const n = buf.length;
    if (n < 0x4c) return Buffer.concat([Buffer.from([n]), buf]);
    if (n <= 0xff) return Buffer.concat([Buffer.from([0x4c, n]), buf]);
    if (n <= 0xffff) {
        const h = Buffer.allocUnsafe(3); h[0] = 0x4d; h.writeUInt16LE(n, 1);
        return Buffer.concat([h, buf]);
    }
    const h = Buffer.allocUnsafe(5); h[0] = 0x4e; h.writeUInt32LE(n, 1);
    return Buffer.concat([h, buf]);
}

/**
 * BIP34 block-height prefix for the coinbase scriptSig.
 *
 * This is not "push the height as data". Consensus builds `CScript() << nHeight`
 * and compares it byte for byte against the start of our scriptSig, so we have
 * to reproduce CScript::push_int64 exactly -- including its small-integer
 * shortcuts, where 1..16 become the single opcodes OP_1..OP_16 rather than a
 * one-byte data push.
 *
 * Getting this wrong is invisible on a chain that is already past block 16, and
 * fatal on one that is not: the pool mined two valid blocks at real difficulty
 * on a fresh testnet and both came back `bad-cb-height`. On launch day that is
 * a chain that never leaves height 0.
 */
function serializeHeight(height) {
    if (height === 0) return Buffer.from([0x00]);                   // OP_0
    if (height >= 1 && height <= 16) {
        return Buffer.from([0x50 + height]);                        // OP_1 .. OP_16
    }

    // Everything else is CScriptNum::serialize pushed as data.
    let hex = height.toString(16);
    if (hex.length % 2) hex = '0' + hex;
    let buf = reverseBuffer(Buffer.from(hex, 'hex'));   // little-endian
    // A high bit in the top byte would read as a negative CScriptNum.
    if (buf[buf.length - 1] & 0x80) buf = Buffer.concat([buf, Buffer.from([0x00])]);
    return pushData(buf);
}

function packUInt32LE(n) { const b = Buffer.allocUnsafe(4); b.writeUInt32LE(n >>> 0, 0); return b; }
function packInt32LE(n)  { const b = Buffer.allocUnsafe(4); b.writeInt32LE(n, 0);        return b; }
function packInt64LE(n)  { const b = Buffer.allocUnsafe(8); b.writeBigInt64LE(BigInt(n), 0); return b; }

// ---------------------------------------------------------------------------
// base58check
// ---------------------------------------------------------------------------

function base58Decode(str) {
    let n = 0n;
    for (const ch of str) {
        const i = B58.indexOf(ch);
        if (i < 0) throw new Error(`invalid base58 character '${ch}'`);
        n = n * 58n + BigInt(i);
    }
    let hex = n.toString(16);
    if (hex.length % 2) hex = '0' + hex;
    let buf = n === 0n ? Buffer.alloc(0) : Buffer.from(hex, 'hex');

    let leading = 0;
    while (leading < str.length && str[leading] === '1') leading++;
    return Buffer.concat([Buffer.alloc(leading), buf]);
}

function addressToHash160(address) {
    const raw = base58Decode(address);
    if (raw.length !== 25) {
        throw new Error(`address '${address}' decodes to ${raw.length} bytes, expected 25`);
    }
    const payload = raw.subarray(0, 21);
    const checksum = raw.subarray(21);
    if (!sha256d(payload).subarray(0, 4).equals(checksum)) {
        throw new Error(`address '${address}' has a bad checksum -- it is mistyped`);
    }
    return { version: payload[0], hash: payload.subarray(1) };
}

/** OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG */
function p2pkhScript(hash160Buf) {
    return Buffer.concat([Buffer.from([0x76, 0xa9, 0x14]), hash160Buf,
                          Buffer.from([0x88, 0xac])]);
}

/** OP_HASH160 <20> OP_EQUAL */
function p2shScript(hash160Buf) {
    return Buffer.concat([Buffer.from([0xa9, 0x14]), hash160Buf, Buffer.from([0x87])]);
}

// ---------------------------------------------------------------------------
// bech32 / bech32m  (BIP-173, BIP-350)
// ---------------------------------------------------------------------------
//
// Modern Bitcoin Core hands out segwit addresses by default -- `getnewaddress`
// with no arguments returns bech32. A pool that only understands base58 would
// therefore reject the address of almost every miner who connects to it, and
// could not even pay itself. This is not an optional extra.

const BECH32_CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const BECH32_CONST = 1;
const BECH32M_CONST = 0x2bc830a3;

function bech32Polymod(values) {
    const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
    let chk = 1;
    for (const v of values) {
        const top = chk >> 25;
        chk = ((chk & 0x1ffffff) << 5) ^ v;
        for (let i = 0; i < 5; i++) {
            if ((top >> i) & 1) chk ^= GEN[i];
        }
    }
    return chk >>> 0;
}

function bech32HrpExpand(hrp) {
    const out = [];
    for (let i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) >> 5);
    out.push(0);
    for (let i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) & 31);
    return out;
}

/** Regroup bits, e.g. the 5-bit bech32 payload into 8-bit bytes. */
function convertBits(data, from, to, pad) {
    let acc = 0;
    let bits = 0;
    const out = [];
    const maxv = (1 << to) - 1;

    for (const value of data) {
        if (value < 0 || value >> from !== 0) throw new Error('invalid value in bit conversion');
        acc = (acc << from) | value;
        bits += from;
        while (bits >= to) {
            bits -= to;
            out.push((acc >> bits) & maxv);
        }
    }
    if (pad) {
        if (bits > 0) out.push((acc << (to - bits)) & maxv);
    } else if (bits >= from || ((acc << (to - bits)) & maxv)) {
        throw new Error('invalid padding in bit conversion');
    }
    return out;
}

/**
 * Decode a segwit address. Returns {hrp, version, program} or throws.
 *
 * Enforces the BIP-350 rule that witness v0 uses the bech32 checksum constant
 * and v1+ uses bech32m. Accepting the wrong one is how a taproot address gets
 * paid as if it were v0 -- the funds are not lost, but they are unspendable by
 * the recipient, which for a mining payout is the same thing.
 */
function decodeBech32(address) {
    const lower = address.toLowerCase();
    if (address !== lower && address !== address.toUpperCase()) {
        throw new Error('bech32 address mixes upper and lower case');
    }
    if (lower.length < 8 || lower.length > 90) {
        throw new Error(`bech32 address length ${lower.length} is out of range`);
    }

    const sep = lower.lastIndexOf('1');
    if (sep < 1 || sep + 7 > lower.length) {
        throw new Error('bech32 separator is missing or misplaced');
    }

    const hrp = lower.slice(0, sep);
    const data = [];
    for (const ch of lower.slice(sep + 1)) {
        const i = BECH32_CHARSET.indexOf(ch);
        if (i < 0) throw new Error(`'${ch}' is not a bech32 character`);
        data.push(i);
    }

    const checksum = bech32Polymod(bech32HrpExpand(hrp).concat(data));
    const version = data[0];

    const expected = version === 0 ? BECH32_CONST : BECH32M_CONST;
    if (checksum !== expected) {
        throw new Error(
            checksum === (version === 0 ? BECH32M_CONST : BECH32_CONST)
                ? `witness v${version} must use ${version === 0 ? 'bech32' : 'bech32m'} ` +
                  'but the checksum is the other one'
                : 'bech32 checksum failed -- the address is mistyped');
    }

    if (version > 16) throw new Error(`witness version ${version} is out of range`);

    const program = Buffer.from(convertBits(data.slice(1, -6), 5, 8, false));
    if (program.length < 2 || program.length > 40) {
        throw new Error(`witness program length ${program.length} is invalid`);
    }
    if (version === 0 && program.length !== 20 && program.length !== 32) {
        throw new Error('witness v0 program must be 20 or 32 bytes');
    }

    return { hrp, version, program };
}

/** OP_<version> <program> -- the segwit output script. */
function witnessScript(version, program) {
    const opVersion = version === 0 ? 0x00 : 0x50 + version;   // OP_0 / OP_1..OP_16
    return Buffer.concat([Buffer.from([opVersion, program.length]), program]);
}

/**
 * Build the locking script for any WAM address.
 *
 * Handles base58 (P2PKH, P2SH) and bech32/bech32m (P2WPKH, P2WSH, P2TR).
 * Throws loudly on anything else rather than producing a script that would
 * silently burn a block reward or a miner's payout.
 */
function addressToScript(address, netVersions) {
    const hrp = netVersions.bech32;

    // bech32 first: its addresses are unambiguous by prefix.
    if (hrp && address.toLowerCase().startsWith(hrp + '1')) {
        const { hrp: got, version, program } = decodeBech32(address);
        if (got !== hrp) {
            throw new Error(
                `address '${address}' is for network '${got}', not '${hrp}'. ` +
                'Refusing to pay to another chain.');
        }
        return witnessScript(version, program);
    }

    // Catch a segwit address belonging to some OTHER chain before it falls
    // through to the base58 decoder, which would report a meaningless
    // "invalid base58 character" and leave the miner guessing. Pasting a
    // Bitcoin or Litecoin address into a WAM pool is a routine mistake and
    // deserves a routine answer.
    const looksBech32 = /^[a-z0-9]{1,20}1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{6,}$/i
        .test(address);
    if (looksBech32) {
        const otherHrp = address.slice(0, address.lastIndexOf('1')).toLowerCase();
        const known = { bc: 'Bitcoin mainnet', tb: 'Bitcoin testnet',
                        bcrt: 'Bitcoin regtest', ltc: 'Litecoin' }[otherHrp];
        throw new Error(
            `'${address}' is a segwit address for '${otherHrp}'` +
            (known ? ` (${known})` : '') +
            `, not for WAM. A ${netVersions.bech32 ? `'${netVersions.bech32}1…'` : 'WAM'} ` +
            'address is required. Coins sent to another chain\'s address are lost.');
    }

    const { version, hash } = addressToHash160(address);
    if (version === netVersions.pubkey) return p2pkhScript(hash);
    if (version === netVersions.script) return p2shScript(hash);

    throw new Error(
        `address '${address}' has version byte ${version}, which is neither the ` +
        `P2PKH version (${netVersions.pubkey}) nor the P2SH version ` +
        `(${netVersions.script}) for this network. Refusing to mine to it.`);
}

/**
 * Validate an address without building a script. Used when a miner authorises.
 * Returns {ok, kind} or {ok:false, reason}.
 */
function validateAddress(address, netVersions) {
    if (!address || typeof address !== 'string') {
        return { ok: false, reason: 'empty address' };
    }
    try {
        addressToScript(address, netVersions);
        const hrp = netVersions.bech32;
        const isBech32 = hrp && address.toLowerCase().startsWith(hrp + '1');
        return { ok: true, kind: isBech32 ? 'bech32' : 'base58' };
    } catch (err) {
        return { ok: false, reason: err.message };
    }
}

// ---------------------------------------------------------------------------
// Merkle
// ---------------------------------------------------------------------------

/**
 * Merkle branch for the coinbase (always index 0), computed once per template.
 * `txHashes` are the txids of every non-coinbase transaction, little-endian.
 */
function buildMerkleBranch(txHashes) {
    const branch = [];
    let layer = txHashes.slice();
    while (layer.length > 0) {
        branch.push(layer[0]);
        if (layer.length === 1) break;
        const next = [];
        // The coinbase occupies the implicit slot 0, so pairing starts at 1.
        for (let i = 1; i < layer.length; i += 2) {
            const right = (i + 1 < layer.length) ? layer[i + 1] : layer[i];
            next.push(sha256d(Buffer.concat([layer[i], right])));
        }
        layer = next;
    }
    return branch;
}

/** Fold a coinbase hash through a precomputed branch to get the merkle root. */
function applyMerkleBranch(coinbaseHash, branch) {
    let root = coinbaseHash;
    for (const node of branch) {
        root = sha256d(Buffer.concat([root, node]));
    }
    return root;
}

// ---------------------------------------------------------------------------
// Difficulty
// ---------------------------------------------------------------------------

/** nBits -> 256-bit target. Mirrors compact_to_target() in the Python tools. */
function bitsToTarget(bits) {
    const b = BigInt(bits);
    const exponent = b >> 24n;
    const mantissa = b & 0x007fffffn;
    return exponent <= 3n
        ? mantissa >> (8n * (3n - exponent))
        : mantissa << (8n * (exponent - 3n));
}

/** Share difficulty -> target, using the RandomX diff-1 convention. */
function difficultyToTarget(difficulty) {
    // Scale by 2^32 first so that fractional difficulties (vardiff hands out
    // values like 0.25) survive integer division.
    const scaled = BigInt(Math.round(difficulty * 4294967296));
    if (scaled <= 0n) throw new Error('difficulty must be positive');
    return (DIFF1 * 4294967296n) / scaled;
}

/** A 32-byte little-endian hash as a BigInt, matching arith_uint256. */
function hashToBigIntLE(buf) {
    return BigInt('0x' + reverseBuffer(buf).toString('hex'));
}

function targetToDifficulty(target) {
    if (target <= 0n) return 0;
    // Keep 6 decimal places without losing precision to double conversion.
    return Number((DIFF1 * 1000000n) / target) / 1000000;
}

function wamToSatoshi(wam) { return Math.round(wam * COIN); }
function satoshiToWam(sat) { return Number(sat) / COIN; }

module.exports = {
    sha256, sha256d, hash160,
    reverseBuffer, reverseByteOrder,
    varIntBuffer, pushData, serializeHeight,
    packUInt32LE, packInt32LE, packInt64LE,
    base58Decode, addressToHash160, addressToScript, validateAddress,
    p2pkhScript, p2shScript, decodeBech32, witnessScript, convertBits,
    buildMerkleBranch, applyMerkleBranch,
    bitsToTarget, difficultyToTarget, targetToDifficulty, hashToBigIntLE,
    wamToSatoshi, satoshiToWam
};

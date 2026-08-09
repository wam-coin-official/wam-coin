#!/usr/bin/env node
'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  WAM Coin Stratum Pool -- entry point
// ===========================================================================
//
//    node server.js [--config config.json]
//
//  Startup order matters and is enforced:
//    1. load and validate config (fail fast on anything nonsensical)
//    2. connect to Redis and to at least one wamd
//    3. verify the pool's own payout address against THIS network
//    4. self-test the RandomX addon
//    5. pull the first block template (proves the daemon is patched)
//    6. only then open the stratum port
//
//  A pool that opens its port before step 5 will happily accept shares it can
//  never turn into a block.

const fs = require('fs');
const path = require('path');

const Redis = require('ioredis');

const Logger = require('./lib/logger');
const DaemonInterface = require('./lib/daemon');
const JobManager = require('./lib/jobManager');
const StratumServer = require('./lib/stratumServer');
const ShareProcessor = require('./lib/shareProcessor');
const ApiServer = require('./lib/api');
const { ADDRESS_VERSIONS, RANDOMX_EPOCH_BLOCKS, RANDOMX_EPOCH_LAG } = require('./lib/constants');
const { validateAddress } = require('./lib/util');

// ---------------------------------------------------------------------------

function parseArgs(argv) {
    const out = { config: path.join(__dirname, 'config.json') };
    for (let i = 2; i < argv.length; i++) {
        if (argv[i] === '--config' && argv[i + 1]) out.config = argv[++i];
        else if (argv[i] === '--help' || argv[i] === '-h') out.help = true;
    }
    return out;
}

function loadConfig(file) {
    if (!fs.existsSync(file)) {
        throw new Error(
            `config file not found: ${file}\n` +
            'Copy config.example.json to config.json and edit it.');
    }

    let cfg;
    try {
        cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (err) {
        throw new Error(`config.json is not valid JSON: ${err.message}`);
    }

    // ---- required ---------------------------------------------------------
    const required = ['poolAddress', 'daemons'];
    for (const key of required) {
        if (!cfg[key]) throw new Error(`config is missing required key '${key}'`);
    }

    cfg.network = cfg.network || 'mainnet';
    if (!ADDRESS_VERSIONS[cfg.network]) {
        throw new Error(`unknown network '${cfg.network}'`);
    }
    cfg.netVersions = ADDRESS_VERSIONS[cfg.network];

    // The epoch rule is the same on every network -- src/wam/pow.cpp does not
    // special-case regtest -- so these are not per-network settings. They were,
    // once: the pool assumed short epochs off mainnet, rotated its key 1,840
    // blocks early, and every block it found came back 'high-hash'. They exist
    // now only to size the rotation countdown on the dashboard; the key itself
    // always comes from the daemon.
    cfg.randomxEpochBlocks = cfg.randomxEpochBlocks || RANDOMX_EPOCH_BLOCKS;
    cfg.randomxEpochLag = cfg.randomxEpochLag || RANDOMX_EPOCH_LAG;

    // ---- sanity -----------------------------------------------------------
    if (cfg.poolFeePercent !== undefined &&
        (cfg.poolFeePercent < 0 || cfg.poolFeePercent >= 100)) {
        throw new Error('poolFeePercent must be in [0, 100)');
    }

    if ((cfg.minimumPayoutWam || 1) <= 0) {
        throw new Error('minimumPayoutWam must be positive');
    }

    for (const d of cfg.daemons) {
        for (const key of ['host', 'port', 'user', 'password']) {
            if (d[key] === undefined) {
                throw new Error(`daemon entry is missing '${key}'`);
            }
        }
        if (d.password === 'CHANGE_ME' || d.password === '') {
            throw new Error('refusing to start with a placeholder RPC password');
        }
    }

    return cfg;
}

// ---------------------------------------------------------------------------

async function main() {
    const args = parseArgs(process.argv);

    if (args.help) {
        console.log('usage: node server.js [--config path/to/config.json]');
        return 0;
    }

    const config = loadConfig(args.config);

    const logger = new Logger({
        level: config.logLevel || 'info',
        file: config.logFile || null
    });
    const log = logger.scope('pool');

    log.info('='.repeat(66));
    log.info(' WAM Coin Stratum Pool');
    log.info('='.repeat(66));
    log.info(`network        : ${config.network}`);
    log.info(`pool address   : ${config.poolAddress}`);
    log.info(`reward mode    : ${(config.rewardMode || 'pplns').toUpperCase()}`);
    log.info(`pool fee       : ${config.poolFeePercent || 1}%`);
    log.info('chain dev fee  : 5% (enforced by consensus, paid by the coinbase)');

    // ---- 1. pool payout address ------------------------------------------
    // Checked before anything expensive: a wrong-network address here means
    // every block the pool ever finds pays into a void.
    {
        const check = validateAddress(config.poolAddress, config.netVersions);
        if (!check.ok) {
            log.error(
                `poolAddress '${config.poolAddress}' is not usable on ${config.network}: ` +
                `${check.reason}`);
            log.error(`${config.network} addresses start with '${config.netVersions.firstChar}' ` +
                      `(base58) or '${config.netVersions.bech32}1' (bech32).`);
            return 1;
        }
        log.info(`pool address is a valid ${check.kind} address`);
    }

    // ---- 2. Redis ---------------------------------------------------------
    const redis = new Redis({
        host: (config.redis && config.redis.host) || '127.0.0.1',
        port: (config.redis && config.redis.port) || 6379,
        password: (config.redis && config.redis.password) || undefined,
        db: (config.redis && config.redis.db) || 0,
        maxRetriesPerRequest: 3,
        lazyConnect: true
    });

    redis.on('error', (err) => logger.scope('redis').error(err.message));

    try {
        await redis.connect();
        await redis.ping();
        log.info('redis connected');
    } catch (err) {
        log.error(`redis unavailable: ${err.message}`);
        return 1;
    }

    // ---- 3. daemons -------------------------------------------------------
    const daemon = new DaemonInterface(config.daemons, logger.scope('daemon'));
    try {
        await daemon.init();
    } catch (err) {
        log.error(err.message);
        return 1;
    }

    // Confirm the daemon agrees about which chain we are on.
    const chainInfo = await daemon.getBlockchainInfo();
    const expectedChain = config.network === 'mainnet' ? 'main'
                        : config.network === 'testnet' ? 'test' : 'regtest';
    if (chainInfo.chain !== expectedChain) {
        log.error(`config says network='${config.network}' but wamd reports ` +
                  `chain='${chainInfo.chain}'. Refusing to start.`);
        return 1;
    }

    // ---- 3b. can this pool actually pay anyone? --------------------------
    // The coinbase pays poolAddress, and payouts are `sendmany` from the
    // daemon's wallet. If that wallet does not hold poolAddress, the pool will
    // mine perfectly and then be unable to move a single coin -- a failure
    // that stays invisible until the first block matures, hours later, with
    // miners already owed money. Better to refuse to start.
    {
        let info;
        try {
            info = await daemon.cmd('getaddressinfo', [config.poolAddress]);
        } catch (err) {
            log.error(`could not check the payout address: ${err.message}`);
            log.error('The pool needs a loaded wallet to pay miners. Load one on ' +
                      'wamd and name it in config.json as daemons[].wallet.');
            return 1;
        }

        if (!info.ismine) {
            log.error(`the wallet does not own ${config.poolAddress}, so this pool ` +
                      'could never pay a miner.');
            log.error('Either set poolAddress to an address from the daemon wallet, ' +
                      'or point daemons[].wallet at the wallet that holds it.');
            return 1;
        }

        const walletName = config.daemons[0].wallet;
        log.info(`payout wallet   : ${walletName ? `'${walletName}'` : '(default)'} ` +
                 `holds the pool address`);
    }

    // ---- 4/5. job manager (self-tests RandomX, pulls the first template) --
    const jobManager = new JobManager(daemon, config, logger.scope('jobs'));

    try {
        await jobManager.start();
    } catch (err) {
        log.error(`could not start the job manager: ${err.message}`);
        return 1;
    }

    // ---- 6. accounting ----------------------------------------------------
    const shareProcessor = new ShareProcessor(redis, daemon, config, logger.scope('shares'));
    shareProcessor.setNetworkDifficulty(chainInfo.difficulty);
    shareProcessor.start();

    jobManager.on('share', (share) => {
        shareProcessor.recordShare(share)
            .catch((err) => log.error(`failed to record a share: ${err.message}`));
    });

    jobManager.on('block', (share) => {
        shareProcessor.recordBlock(share)
            .catch((err) => log.error(`failed to record block ${share.height}: ${err.message}`));
    });

    // ---- 7. stratum -------------------------------------------------------
    const stratum = new StratumServer(jobManager, config, logger.scope('stratum'));
    stratum.listen();

    // ---- 8. dashboard -----------------------------------------------------
    const api = new ApiServer({
        config, logger: logger.scope('api'), jobManager,
        stratumServer: stratum, shareProcessor, daemon
    });
    api.listen();

    // Keep the difficulty used for PPLNS window sizing fresh.
    const diffTimer = setInterval(async () => {
        try {
            const info = await daemon.getBlockchainInfo();
            shareProcessor.setNetworkDifficulty(info.difficulty);
        } catch { /* the daemon layer already logged it */ }
    }, 60000);

    log.info('pool is up');

    // ---- shutdown ---------------------------------------------------------
    let shuttingDown = false;
    const shutdown = async (signal) => {
        if (shuttingDown) return;
        shuttingDown = true;
        log.info(`${signal} received, shutting down`);

        clearInterval(diffTimer);
        stratum.close();
        api.close();
        jobManager.stop();
        shareProcessor.stop();

        try {
            // One last payment run so miners are not left waiting on a restart.
            await shareProcessor.checkPendingBlocks();
        } catch { /* best effort */ }

        await redis.quit().catch(() => {});
        log.info('goodbye');
        process.exit(0);
    };

    process.on('SIGINT', () => shutdown('SIGINT'));
    process.on('SIGTERM', () => shutdown('SIGTERM'));

    process.on('unhandledRejection', (reason) => {
        log.error(`unhandled rejection: ${reason && reason.stack ? reason.stack : reason}`);
    });
    process.on('uncaughtException', (err) => {
        log.error(`uncaught exception: ${err.stack || err.message}`);
        // A pool in an unknown state must not keep taking shares.
        shutdown('uncaughtException');
    });

    return new Promise(() => {});   // run until a signal arrives
}

main().then((code) => {
    if (typeof code === 'number' && code !== 0) process.exit(code);
}).catch((err) => {
    console.error(err.stack || err.message);
    process.exit(1);
});

'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// Read-only HTTP API + static file server for the dashboard.
//
// No framework: the surface is eight endpoints and a handful of static files,
// and an unpatched Express in a pool's public-facing process is a liability
// nobody needs. Everything here is GET, everything is read-only, and nothing
// accepts a body.

const http = require('http');
const fs = require('fs');
const path = require('path');

const {
    COIN, SUBSIDY_HALVING_INTERVAL, INITIAL_BLOCK_SUBSIDY_WAM, MAX_HALVINGS,
    DEVFEE_PERCENT, DEVFEE_LAST_HEIGHT
} = require('./constants');

// The same validator the stratum server authorizes with. Two address checks in
// one process drift apart, and the day they disagree the API answers for a
// string no miner could ever have used -- or refuses one that is paying out.
const { validateAddress } = require('./util');

const MIME = {
    '.html': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.png': 'image/png',
    '.json': 'application/json; charset=utf-8'
};

class ApiServer {
    constructor({ config, logger, jobManager, stratumServer, shareProcessor, daemon }) {
        this.config = config;
        this.log = logger;
        this.jobManager = jobManager;
        this.stratum = stratumServer;
        this.shares = shareProcessor;
        this.daemon = daemon;

        this.webRoot = path.join(__dirname, '..', 'web');
        this.cache = new Map();          // endpoint -> {at, body}
        this.cacheMs = config.apiCacheMs || 3000;
    }

    listen() {
        this.server = http.createServer((req, res) => {
            this._handle(req, res).catch((err) => {
                this.log.error(`api error on ${req.url}: ${err.message}`);
                this._json(res, 500, { error: 'internal error' });
            });
        });

        const port = this.config.apiPort || 8080;
        const bind = this.config.apiBind || '0.0.0.0';

        this.server.on('error', (err) => {
            this.log.error(`api port ${port}: ${err.message}`);
            if (err.code === 'EADDRINUSE') process.exit(1);
        });

        this.server.listen(port, bind, () => {
            this.log.info(`dashboard and API on http://${bind}:${port}/`);
        });
    }

    close() { if (this.server) this.server.close(); }

    // -----------------------------------------------------------------------

    async _handle(req, res) {
        if (req.method !== 'GET' && req.method !== 'HEAD') {
            return this._json(res, 405, { error: 'only GET is supported' });
        }

        // WHATWG URL, not the legacy url.parse(): Node deprecated the latter
        // precisely because its non-standard parsing has produced path-handling
        // CVEs. The base is a throwaway -- only the path and query are used.
        let parsed;
        try {
            parsed = new URL(req.url, 'http://localhost');
        } catch {
            return this._json(res, 400, { error: 'malformed request URL' });
        }
        const pathname = parsed.pathname.replace(/\/+$/, '') || '/';

        res.setHeader('Access-Control-Allow-Origin', this.config.apiCorsOrigin || '*');
        res.setHeader('X-Content-Type-Options', 'nosniff');
        res.setHeader('Referrer-Policy', 'no-referrer');

        if (pathname.startsWith('/api/')) {
            return this._api(pathname, parsed.searchParams, res);
        }
        return this._static(pathname, res);
    }

    async _api(pathname, query, res) {
        // Small TTL cache: a dashboard open in fifty tabs must not turn into
        // fifty Redis round trips per second.
        const cacheKey = pathname + '?' + query.toString();
        const hit = this.cache.get(cacheKey);
        if (hit && Date.now() - hit.at < this.cacheMs) {
            return this._json(res, 200, hit.body, true);
        }

        let body;
        switch (pathname) {
        case '/api/stats':
            body = await this._stats();
            break;
        case '/api/blocks':
            body = (await this.shares.getPoolStats());
            body = {
                confirmed: body.recentBlocks,
                pending: body.pendingBlocks,
                orphaned: body.orphanedBlocks
            };
            break;
        case '/api/miners':
            body = { miners: this.stratum.getConnectedMiners() };
            break;
        case '/api/hashrate':
            body = await this.shares.getHashrateStats();
            break;
        case '/api/payments':
            body = { payments: (await this.shares.getPoolStats()).recentPayments };
            break;
        case '/api/miner': {
            const address = query.get('address');
            if (!address) return this._json(res, 400, { error: 'address required' });

            // Reject before doing any work, and before this string becomes a
            // cache key. Anything that is not shaped like an address cannot
            // have mined here, so answering it costs a Redis round trip and a
            // cache entry to tell someone what they already knew.
            // validateAddress returns {ok, reason}, never a boolean: `!result`
            // is always false and would wave everything through.
            const check = validateAddress(address, this.config.netVersions);
            if (!check.ok) {
                return this._json(res, 400, { error: check.reason });
            }
            body = await this.shares.getMinerStats(address);
            break;
        }
        case '/api/network':
            body = await this._network();
            break;
        case '/api/health':
            body = await this._health();
            break;
        default:
            return this._json(res, 404, { error: 'unknown endpoint' });
        }

        this._cacheSet(cacheKey, body);
        return this._json(res, 200, body);
    }

    /**
     * Store, and keep the cache from becoming the attack.
     *
     * The key contains the query string, and /api/miner?address=... is written
     * by whoever is asking. An unbounded Map keyed on that is a memory
     * exhaustion vector: a million distinct addresses is a million entries the
     * process never releases, and the pool dies of a request pattern rather
     * than of a bug.
     *
     * Bounded with the oldest evicted first. A Map iterates in insertion order,
     * so the first key is the oldest -- no library, no timestamp scan.
     */
    _cacheSet(key, body) {
        const max = this.config.apiCacheEntries || 512;
        if (this.cache.size >= max) {
            // Drop expired entries first; only fall back to evicting a live one
            // if everything in there is still warm.
            const now = Date.now();
            for (const [k, v] of this.cache) {
                if (now - v.at >= this.cacheMs) this.cache.delete(k);
            }
            while (this.cache.size >= max) {
                this.cache.delete(this.cache.keys().next().value);
            }
        }
        this.cache.set(key, { at: Date.now(), body });
    }

    async _stats() {
        const [pool, hashrate, network] = await Promise.all([
            this.shares.getPoolStats(),
            this.shares.getHashrateStats(),
            this._network()
        ]);

        const miners = this.stratum.getConnectedMiners();
        const job = this.jobManager.getStatus();

        // Expected time to a block, given the pool's share of network hashrate.
        const networkHashrate = network.networkHashPerSecond || 0;
        const poolShare = networkHashrate > 0 ? hashrate.poolHashrate / networkHashrate : 0;
        const expectedBlockSeconds = poolShare > 0 ? 120 / poolShare : null;

        return {
            pool: {
                ...pool,
                hashrate: hashrate.poolHashrate,
                miners: miners.length,
                workers: Object.keys(hashrate.workers).length,
                poolSharePercent: poolShare * 100,
                expectedBlockSeconds
            },
            network,
            job: job.currentJob,
            randomx: {
                seedHeight: job.currentJob ? job.currentJob.seedHeight : null,
                nextRotationInBlocks: job.nextSeedRotationIn,
                seedRotations: job.stats ? job.stats.seedRotations : job.seedRotations
            },
            config: {
                rewardMode: pool.rewardMode,
                poolFeePercent: pool.poolFeePercent,
                chainDevFeePercent: 5,
                minimumPayoutWam: this.config.minimumPayoutWam || 1,
                ports: (this.config.ports || []).map((p) => ({
                    port: p.port,
                    difficulty: p.difficulty || this.config.startDifficulty,
                    description: p.description || null,
                    // The dashboard has to say which port is encrypted, or
                    // nobody uses it. An encrypted port that is never
                    // mentioned protects nobody.
                    tls: Boolean(p.tls)
                })),
                stratumHost: this.config.publicHost || null
            },
            updatedAt: Date.now()
        };
    }

    async _network() {
        const [chain, mining] = await Promise.all([
            this.daemon.getBlockchainInfo(),
            this.daemon.getMiningInfo()
        ]);

        this.shares.setNetworkDifficulty(chain.difficulty);

        const height = chain.blocks;

        // The emission comes from the node, not from a constant here.
        //
        // This used to recompute the halving schedule locally from
        // SUBSIDY_HALVING_INTERVAL, and was wrong on every network except
        // mainnet: at regtest height 3,944 it reported a 50.00 WAM block reward
        // and "196,056 blocks to halving 1" while the chain's real subsidy had
        // halved 25 times to 74 satoshi with the next halving 106 blocks away.
        //
        // That was the fourth time this project reimplemented a consensus rule
        // in JavaScript beside a daemon that already returned the answer -- the
        // treasury maths, the RandomX epoch, the network dashboard, and this.
        // The rule, stated once: if the daemon returns it, do not recompute it.
        const supply = await this.daemon.cmd('getsupplyinfo', []).catch(() => null);
        const fromNode = (key) =>
            supply && supply[key] !== undefined && supply[key] !== null;
        const toSat = (wam) => Math.round(Number(wam) * COIN);

        let subsidy, treasurySubsidy, nextHalvingHeight, halvings, emissionSource;

        if (fromNode('halving_interval') && fromNode('block_subsidy')) {
            subsidy = toSat(supply.block_subsidy);
            treasurySubsidy = fromNode('treasury_subsidy')
                ? toSat(supply.treasury_subsidy)
                : Math.floor(subsidy * DEVFEE_PERCENT / 100);
            nextHalvingHeight = fromNode('next_halving_height')
                ? supply.next_halving_height
                : (Math.floor(Math.max(0, height - 1) / supply.halving_interval) + 1)
                  * supply.halving_interval;
            halvings = fromNode('halving_epoch') ? supply.halving_epoch : 0;
            emissionSource = 'node';
        } else {
            // An unpatched or unreachable daemon. Mirrors wam::GetBlockSubsidy,
            // and says so, because these figures are then a guess.
            halvings = height >= 1
                ? Math.floor((height - 1) / SUBSIDY_HALVING_INTERVAL) : 0;
            subsidy = halvings >= MAX_HALVINGS
                ? 0 : Math.floor(INITIAL_BLOCK_SUBSIDY_WAM * COIN / Math.pow(2, halvings));
            nextHalvingHeight = (halvings + 1) * SUBSIDY_HALVING_INTERVAL;
            treasurySubsidy = (height >= 1 && height <= DEVFEE_LAST_HEIGHT)
                ? Math.floor(subsidy * DEVFEE_PERCENT / 100) : 0;
            emissionSource = 'local';
        }

        const treasuryActive = treasurySubsidy > 0;

        return {
            emissionSource,
            chain: chain.chain,
            blocks: chain.blocks,
            headers: chain.headers,
            difficulty: chain.difficulty,
            networkHashPerSecond: mining.networkhashps || 0,

            // The tip's own timestamp, and how long ago that was.
            //
            // networkhashps above is an ESTIMATE derived from how fast recent
            // blocks arrived. When blocks stop arriving it keeps reporting the
            // rate of the blocks before the stall, so it is least truthful at
            // the exact moment it matters most. On 5 September 2026 a tester
            // shut down every miner he had; this page read 24.3 kH/s while
            // showing 0 active workers, and the chain had not moved in half an
            // hour. Both numbers were on screen together.
            //
            // This one cannot be estimated: it is the clock minus the block
            // header. The page shows it beside the hashrate so a reader can
            // see when the estimate has gone stale.
            tipTime: chain.time || null,
            secondsSinceBlock: chain.time
                ? Math.max(0, Math.floor(Date.now() / 1000) - chain.time)
                : null,
            connections: mining.connections !== undefined ? mining.connections : null,
            blockSubsidy: subsidy,
            minerSubsidy: subsidy - treasurySubsidy,
            treasurySubsidy,
            treasuryActive,
            // From the chain where it says so. It happens to agree with
            // DEVFEE_LAST_HEIGHT today, and the whole lesson of this file is
            // that "happens to agree" is not a property you can rely on.
            treasuryLastHeight: fromNode('treasury') && supply.treasury.last_height !== undefined
                ? supply.treasury.last_height : DEVFEE_LAST_HEIGHT,
            blocksUntilTreasuryEnds: fromNode('treasury') &&
                                     supply.treasury.blocks_remaining !== undefined
                ? supply.treasury.blocks_remaining
                : Math.max(0, DEVFEE_LAST_HEIGHT - height),
            halvingEpoch: halvings,
            nextHalvingHeight,
            blocksUntilHalving: nextHalvingHeight - height,
            targetSpacing: 120
        };
    }

    async _health() {
        const job = this.jobManager.getStatus();
        const templateAgeSec = (Date.now() - this.jobManager.lastTemplateAt) / 1000;

        const problems = [];
        if (!job.currentJob) problems.push('no block template');
        if (templateAgeSec > 120) problems.push(`template is ${Math.round(templateAgeSec)}s old`);
        if (this.stratum.clients.size === 0) problems.push('no miners connected');

        return {
            ok: problems.length === 0,
            problems,
            templateAgeSec: Math.round(templateAgeSec),
            connections: this.stratum.clients.size,
            uptimeSec: Math.round(process.uptime()),
            memoryMb: Math.round(process.memoryUsage().rss / 1048576)
        };
    }

    // -----------------------------------------------------------------------

    _static(pathname, res) {
        const rel = pathname === '/' ? 'index.html' : pathname.slice(1);

        // Resolve and then verify containment: this is the only defence that
        // actually works against encoded traversal sequences.
        const filePath = path.resolve(this.webRoot, rel);
        if (!filePath.startsWith(path.resolve(this.webRoot) + path.sep)) {
            return this._json(res, 403, { error: 'forbidden' });
        }

        fs.readFile(filePath, (err, data) => {
            if (err) return this._json(res, 404, { error: 'not found' });
            res.writeHead(200, {
                'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream',
                'Cache-Control': 'public, max-age=60'
            });
            res.end(data);
        });
    }

    _json(res, status, body, cached = false) {
        const text = JSON.stringify(body);
        res.writeHead(status, {
            'Content-Type': 'application/json; charset=utf-8',
            'Content-Length': Buffer.byteLength(text),
            'X-Cache': cached ? 'HIT' : 'MISS'
        });
        res.end(text);
    }
}

module.exports = ApiServer;

'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// JSON-RPC client for wamd, with failover across a list of daemons.
//
// Design notes:
//  * `cmd()` targets the first responsive daemon; `cmdAll()` broadcasts. Block
//    submission uses cmdAll deliberately -- if one node is wedged, a found
//    block must not be lost because of it.
//  * Errors are never swallowed. A pool that hides RPC failures ends up
//    silently mining stale templates.

const http = require('http');
const https = require('https');
const EventEmitter = require('events');

class DaemonInterface extends EventEmitter {
    /**
     * @param {Array<{host,port,user,password,ssl?}>} daemons
     * @param {object} logger scoped logger
     */
    constructor(daemons, logger) {
        super();
        if (!Array.isArray(daemons) || daemons.length === 0) {
            throw new Error('at least one daemon must be configured');
        }
        this.daemons = daemons.map((d, i) => ({ ...d, index: i, online: false }));
        this.log = logger;
        this.rpcId = 0;
    }

    /**
     * Probe every daemon; resolves once at least one answers getblockchaininfo.
     *
     * Waits rather than failing on the first attempt. A node that is starting
     * takes a minute or two to load its block index and wallets, and answers
     * ECONNREFUSED or RPC_IN_WARMUP (-28) throughout -- so at boot the pool
     * used to exit immediately, systemd restarted it, and the two raced until
     * the node happened to win. With StartLimitBurst=5 that race can end with
     * systemd giving up permanently, leaving the pool down after every reboot
     * until somebody notices and runs reset-failed by hand.
     *
     * Refusing to run without a node is still right; doing it in under a
     * second was not. A node that is booting appears within a minute, and one
     * that is misconfigured never appears -- only elapsed time tells them
     * apart, so this spends the time and then says which case it was.
     */
    async init(waitSeconds = 180) {
        const deadline = Date.now() + waitSeconds * 1000;
        let attempt = 0;
        let announcedWait = false;

        for (;;) {
            attempt++;
            const results = await Promise.allSettled(
                this.daemons.map((d) => this._request(d, 'getblockchaininfo', []))
            );

            let lastReason = '';
            results.forEach((r, i) => {
                const d = this.daemons[i];
                d.online = r.status === 'fulfilled';
                if (d.online) {
                    const info = r.value;
                    this.log.info(`daemon ${d.host}:${d.port} online -- chain=${info.chain} ` +
                                  `blocks=${info.blocks} difficulty=${info.difficulty}`);
                } else {
                    lastReason = r.reason.message;
                    // Only the first failure is an error; the rest are a wait.
                    if (attempt === 1) {
                        this.log.error(`daemon ${d.host}:${d.port} unreachable: ${lastReason}`);
                    }
                }
            });

            if (this.daemons.some((d) => d.online)) return;

            if (Date.now() >= deadline) {
                throw new Error(
                    `no wamd instance became reachable within ${waitSeconds}s ` +
                    `(${attempt} attempts, last: ${lastReason}) -- refusing to start. ` +
                    'Check that wamd is running and that rpcuser/rpcpassword match.');
            }

            if (!announcedWait) {
                announcedWait = true;
                this.log.warn(`waiting up to ${waitSeconds}s for a daemon ` +
                              '(this is normal while a node loads its block index)');
            }
            await new Promise((r) => setTimeout(r, 3000));
        }
    }

    /** Call the first online daemon, failing over on error. */
    async cmd(method, params = []) {
        const ordered = [...this.daemons.filter((d) => d.online),
                         ...this.daemons.filter((d) => !d.online)];
        let lastError;
        for (const d of ordered) {
            try {
                const result = await this._request(d, method, params);
                if (!d.online) {
                    d.online = true;
                    this.log.info(`daemon ${d.host}:${d.port} recovered`);
                }
                return result;
            } catch (err) {
                lastError = err;
                if (d.online) {
                    d.online = false;
                    this.log.warn(`daemon ${d.host}:${d.port} failed on ${method}: ${err.message}`);
                }
            }
        }
        throw new Error(`all daemons failed for ${method}: ${lastError && lastError.message}`);
    }

    /** Broadcast to every daemon and return each outcome. */
    async cmdAll(method, params = []) {
        const settled = await Promise.allSettled(
            this.daemons.map((d) => this._request(d, method, params))
        );
        return settled.map((r, i) => ({
            daemon: `${this.daemons[i].host}:${this.daemons[i].port}`,
            ok: r.status === 'fulfilled',
            result: r.status === 'fulfilled' ? r.value : null,
            error: r.status === 'rejected' ? r.reason.message : null
        }));
    }

    _request(daemon, method, params) {
        return new Promise((resolve, reject) => {
            const body = JSON.stringify({
                jsonrpc: '2.0',
                id: ++this.rpcId,
                method,
                params
            });

            const auth = Buffer.from(`${daemon.user}:${daemon.password}`).toString('base64');
            const transport = daemon.ssl ? https : http;

            // Wallet routing. A node with more than one wallet loaded rejects
            // every wallet RPC sent to '/' with "wallet file not specified",
            // so `sendmany` fails and miners never get paid -- on a node that
            // otherwise looks perfectly healthy. Bitcoin Core serves node RPCs
            // on the wallet endpoint too, so when a wallet is named we can send
            // everything there and keep one code path.
            const path = daemon.wallet
                ? `/wallet/${encodeURIComponent(daemon.wallet)}`
                : '/';

            const req = transport.request({
                host: daemon.host,
                port: daemon.port,
                method: 'POST',
                path,
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(body),
                    'Authorization': `Basic ${auth}`
                },
                timeout: daemon.timeout || 15000
            }, (res) => {
                const chunks = [];
                res.on('data', (c) => chunks.push(c));
                res.on('end', () => {
                    const text = Buffer.concat(chunks).toString('utf8');

                    if (res.statusCode === 401) {
                        return reject(new Error('RPC authentication failed (401) -- ' +
                            'rpcuser/rpcpassword in config.json do not match wam.conf'));
                    }

                    let parsed;
                    try {
                        parsed = JSON.parse(text);
                    } catch {
                        return reject(new Error(
                            `non-JSON reply (HTTP ${res.statusCode}): ${text.slice(0, 200)}`));
                    }

                    if (parsed.error) {
                        const e = new Error(parsed.error.message || JSON.stringify(parsed.error));
                        e.code = parsed.error.code;
                        return reject(e);
                    }
                    resolve(parsed.result);
                });
            });

            req.on('error', reject);
            req.on('timeout', () => {
                req.destroy(new Error(`RPC timeout calling ${method}`));
            });
            req.end(body);
        });
    }

    // -----------------------------------------------------------------------
    // Typed convenience wrappers
    // -----------------------------------------------------------------------

    getBlockTemplate() {
        return this.cmd('getblocktemplate', [{ rules: ['segwit'] }]);
    }

    getBlockchainInfo() { return this.cmd('getblockchaininfo'); }
    getMiningInfo()     { return this.cmd('getmininginfo'); }
    getBlockHash(h)     { return this.cmd('getblockhash', [h]); }
    getBlock(hash, v)   { return this.cmd('getblock', v === undefined ? [hash] : [hash, v]); }
    getBalance()        { return this.cmd('getbalance'); }
    validateAddress(a)  { return this.cmd('validateaddress', [a]); }

    /** Submit to every daemon; a block is too valuable to send to just one. */
    async submitBlock(hexData) {
        const results = await this.cmdAll('submitblock', [hexData]);

        // submitblock returns null on success and a reject-reason string
        // otherwise -- an inverted convention that is very easy to misread.
        const accepted = results.filter((r) => r.ok && (r.result === null || r.result === undefined));
        const rejected = results.filter((r) => !accepted.includes(r));

        return {
            accepted: accepted.length > 0,
            reasons: rejected.map((r) => `${r.daemon}: ${r.error || r.result}`),
            results
        };
    }
}

module.exports = DaemonInterface;

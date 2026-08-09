'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// Minimal JSON-RPC client for wamd, built on Node's http module only.
//
// The explorer has ZERO npm dependencies on purpose. It is the tool an operator
// reaches for when something is wrong, and "npm install failed" is not an
// acceptable answer at that moment. `node server.js` and it runs.

const http = require('http');
const https = require('https');

class RpcClient {
    constructor({ host, port, user, password, ssl = false, timeout = 10000 }) {
        Object.assign(this, { host, port, user, password, ssl, timeout });
        this.id = 0;
        this.lastError = null;
        this.online = false;
    }

    call(method, params = []) {
        return new Promise((resolve, reject) => {
            const body = JSON.stringify({ jsonrpc: '2.0', id: ++this.id, method, params });
            const auth = Buffer.from(`${this.user}:${this.password}`).toString('base64');
            const transport = this.ssl ? https : http;

            const req = transport.request({
                host: this.host,
                port: this.port,
                method: 'POST',
                path: '/',
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(body),
                    Authorization: `Basic ${auth}`
                },
                timeout: this.timeout
            }, (res) => {
                const chunks = [];
                res.on('data', (c) => chunks.push(c));
                res.on('end', () => {
                    const text = Buffer.concat(chunks).toString('utf8');

                    if (res.statusCode === 401) {
                        this.online = false;
                        return reject(new Error(
                            'RPC authentication failed (401). rpcuser/rpcpassword in the ' +
                            'explorer config do not match wam.conf.'));
                    }

                    let parsed;
                    try {
                        parsed = JSON.parse(text);
                    } catch {
                        this.online = false;
                        return reject(new Error(
                            `non-JSON reply (HTTP ${res.statusCode}): ${text.slice(0, 160)}`));
                    }

                    if (parsed.error) {
                        // An RPC-level error still means the node answered.
                        this.online = true;
                        const err = new Error(parsed.error.message || 'rpc error');
                        err.code = parsed.error.code;
                        return reject(err);
                    }

                    this.online = true;
                    this.lastError = null;
                    resolve(parsed.result);
                });
            });

            req.on('error', (err) => {
                this.online = false;
                this.lastError = err.message;
                reject(new Error(
                    err.code === 'ECONNREFUSED'
                        ? `wamd is not reachable at ${this.host}:${this.port}. Is it running?`
                        : err.message));
            });

            req.on('timeout', () => {
                req.destroy(new Error(`RPC timeout calling ${method}`));
            });

            req.end(body);
        });
    }

    /**
     * Call that resolves to `fallback` instead of throwing.
     *
     * Used for the WAM-specific RPCs (getsupplyinfo, getrandomxinfo, ...). An
     * explorer pointed at a stock bitcoind, or at a wamd built before those
     * commands existed, should degrade to showing less -- not crash.
     */
    async tryCall(method, params = [], fallback = null) {
        try {
            return await this.call(method, params);
        } catch (err) {
            if (err.code === -32601) return fallback;   // method not found
            throw err;
        }
    }
}

module.exports = RpcClient;

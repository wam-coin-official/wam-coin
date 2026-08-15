'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// The two things the announcement bot reads: a WAM node, and GitHub.
//
// Where it *writes* is in sinks.js. Reading and writing are separated because
// the credentials are: this file holds RPC access to a local node, that one
// holds the keys to public channels, and they should not be able to leak into
// each other's errors.
//
// Both are a dozen lines of `http`. Neither needs a dependency, and for a
// process that holds channel credentials and runs unattended, every dependency
// it does not have is one that cannot be compromised on its behalf.
// ---------------------------------------------------------------------------

const http = require('http');
const https = require('https');

/** JSON-RPC to wamd. Throws on anything that is not a clean result. */
class NodeRpc {
    constructor({ host = '127.0.0.1', port, user, password, wallet = null, timeout = 15000 }) {
        Object.assign(this, { host, port, user, password, wallet, timeout });
        this.id = 0;
    }

    call(method, params = []) {
        return new Promise((resolve, reject) => {
            const body = JSON.stringify({ jsonrpc: '2.0', id: ++this.id, method, params });
            const auth = Buffer.from(`${this.user}:${this.password}`).toString('base64');

            const req = http.request({
                host: this.host,
                port: this.port,
                method: 'POST',
                path: this.wallet ? `/wallet/${encodeURIComponent(this.wallet)}` : '/',
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
                        return reject(new Error('RPC authentication failed -- check rpcuser/rpcpassword'));
                    }
                    let parsed;
                    try {
                        parsed = JSON.parse(text);
                    } catch {
                        return reject(new Error(`non-JSON reply from wamd: ${text.slice(0, 160)}`));
                    }
                    if (parsed.error) return reject(new Error(parsed.error.message || 'RPC error'));
                    resolve(parsed.result);
                });
            });

            req.on('timeout', () => req.destroy(new Error('RPC timed out')));
            req.on('error', reject);
            req.write(body);
            req.end();
        });
    }
}

/**
 * The latest published release, straight from GitHub's public API.
 *
 * Unauthenticated on purpose. A GitHub Actions workflow would need the channel
 * credentials stored as repository secrets, which puts the keys to the
 * announcement channels inside a system that does not need them. Sixty requests
 * an hour is the anonymous limit and this uses twelve.
 */
function latestRelease(repo, timeout = 15000) {
    return new Promise((resolve) => {
        const req = https.request({
            host: 'api.github.com',
            path: `/repos/${repo}/releases/latest`,
            headers: { 'User-Agent': 'wam-announce', Accept: 'application/vnd.github+json' },
            timeout
        }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => {
                if (res.statusCode !== 200) return resolve(null);   // no releases yet, or rate limited
                try {
                    const r = JSON.parse(Buffer.concat(chunks).toString('utf8'));
                    resolve({ tag: r.tag_name, name: r.name, url: r.html_url, body: r.body || '' });
                } catch {
                    resolve(null);
                }
            });
        });
        // A GitHub outage must never stop the chain announcements.
        req.on('timeout', () => { req.destroy(); resolve(null); });
        req.on('error', () => resolve(null));
        req.end();
    });
}

module.exports = { NodeRpc, latestRelease };

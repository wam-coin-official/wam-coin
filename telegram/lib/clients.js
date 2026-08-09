'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// The two things this bot talks to: a WAM node, and Telegram.
//
// Both are a dozen lines of `http`. Neither needs a dependency, and for a
// process that holds a bot token and runs unattended, every dependency it does
// not have is one that cannot be compromised on its behalf.
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
 * Telegram's sendMessage.
 *
 * HTML parse mode, because escaping it correctly needs three replacements
 * while MarkdownV2 needs eighteen -- and a message that fails to parse is a
 * message nobody receives.
 */
class Telegram {
    constructor({ token, chatId, timeout = 20000 }) {
        Object.assign(this, { token, chatId, timeout });
    }

    /** Escape text that came from anywhere other than this file. */
    static escape(text) {
        return String(text)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;');
    }

    send(text, { silent = false } = {}) {
        return new Promise((resolve, reject) => {
            const body = JSON.stringify({
                chat_id: this.chatId,
                text,
                parse_mode: 'HTML',
                disable_web_page_preview: true,
                disable_notification: silent
            });

            const req = https.request({
                host: 'api.telegram.org',
                method: 'POST',
                path: `/bot${this.token}/sendMessage`,
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(body)
                },
                timeout: this.timeout
            }, (res) => {
                const chunks = [];
                res.on('data', (c) => chunks.push(c));
                res.on('end', () => {
                    let parsed;
                    try {
                        parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
                    } catch {
                        return reject(new Error(`Telegram returned non-JSON (HTTP ${res.statusCode})`));
                    }
                    // The token is never in the response, so this is safe to surface.
                    if (!parsed.ok) {
                        return reject(new Error(
                            `Telegram refused the message: ${parsed.error_code} ${parsed.description}`));
                    }
                    resolve(parsed.result);
                });
            });

            req.on('timeout', () => req.destroy(new Error('Telegram timed out')));
            req.on('error', reject);
            req.write(body);
            req.end();
        });
    }
}

/**
 * The latest published release, straight from GitHub's public API.
 *
 * Unauthenticated on purpose. A GitHub Actions workflow would need the bot
 * token stored as a repository secret, which puts the key to the announcement
 * channel inside a system that does not need it. Sixty requests an hour is the
 * anonymous limit and this uses twelve.
 */
function latestRelease(repo, timeout = 15000) {
    return new Promise((resolve) => {
        const req = https.request({
            host: 'api.github.com',
            path: `/repos/${repo}/releases/latest`,
            headers: { 'User-Agent': 'wam-telegram-bot', Accept: 'application/vnd.github+json' },
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

module.exports = { NodeRpc, Telegram, latestRelease };

'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// Where an announcement goes.
//
// Each sink takes a message in the neutral markup from markup.js, renders it
// for its own service, and sends it. Nothing above this file knows which
// services exist; nothing in this file knows what the messages mean. Adding a
// third service is a class here and a line of config, and no change at all to
// the fifteen places that build messages.
//
// Both sinks share two rules that are not optional:
//
//   The credential never reaches a log. A Telegram token sits in the URL path
//   and a Discord webhook *is* a URL with its token inside it, so any error
//   that quotes the request URL publishes the key to the channel. Every error
//   raised here is scrubbed on the way out.
//
//   A message can never mention anybody. Announcement text includes release
//   titles and notes written by other people; "@everyone" in a GitHub release
//   would otherwise ping an entire Discord server, from a bot nobody can talk
//   back to. Discord lets this be denied at the API level rather than filtered
//   in text, which is the difference between a rule and a hope.
// ---------------------------------------------------------------------------

const https = require('https');
const { URL } = require('url');
const { toTelegram, toDiscord } = require('./markup');

/** Telegram accepts 4096 characters; Discord accepts 2000. */
const TELEGRAM_LIMIT = 4096;
const DISCORD_LIMIT = 2000;

/**
 * Remove anything credential-shaped from text that is about to be logged.
 *
 * Belt and braces: the sinks already avoid putting URLs into their errors, but
 * a message from `https`, from DNS, or from a future edit can carry one, and a
 * leaked webhook is a channel anyone can post to as WAM.
 */
function scrub(text) {
    return String(text)
        .replace(/https:\/\/discord(app)?\.com\/api\/webhooks\/\d+\/[\w-]+/g,
                 'https://discord.com/api/webhooks/<redacted>')
        .replace(/\/bot\d+:[\w-]+/g, '/bot<redacted>')
        .replace(/\b\d{6,}:[A-Za-z0-9_-]{30,}\b/g, '<redacted>');
}

/** POST a JSON body and resolve with {status, text}. Never rejects with a URL. */
function postJson(target, body, timeout, label) {
    return new Promise((resolve, reject) => {
        const payload = JSON.stringify(body);
        const req = https.request({
            protocol: target.protocol,
            host: target.hostname,
            port: target.port || 443,
            path: target.pathname + target.search,
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(payload),
                'User-Agent': 'wam-announce'
            },
            timeout
        }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => resolve({
                status: res.statusCode,
                headers: res.headers,
                text: Buffer.concat(chunks).toString('utf8')
            }));
        });

        req.on('timeout', () => req.destroy(new Error(`${label} timed out`)));
        req.on('error', (err) => reject(new Error(`${label}: ${scrub(err.message)}`)));
        req.write(payload);
        req.end();
    });
}

/** Cut to a limit on a line boundary where possible, and say that it was cut. */
function fit(text, limit) {
    if (text.length <= limit) return text;
    const room = limit - 3;
    const cut = text.lastIndexOf('\n', room);
    return (cut > room * 0.6 ? text.slice(0, cut) : text.slice(0, room)) + '...';
}

// ---------------------------------------------------------------------------

class TelegramSink {
    constructor({ token, chatId, timeout = 20000 }) {
        if (!token) throw new Error('telegram: no token configured');
        if (!chatId) throw new Error('telegram: no chatId configured');
        Object.assign(this, { token, chatId, timeout });
    }

    get name() { return 'telegram'; }

    async send(message, { silent = false } = {}) {
        const target = new URL(`https://api.telegram.org/bot${this.token}/sendMessage`);
        const res = await postJson(target, {
            chat_id: this.chatId,
            text: fit(toTelegram(message), TELEGRAM_LIMIT),
            parse_mode: 'HTML',
            disable_web_page_preview: true,
            disable_notification: silent
        }, this.timeout, 'telegram');

        let parsed;
        try {
            parsed = JSON.parse(res.text);
        } catch {
            throw new Error(`telegram returned non-JSON (HTTP ${res.status})`);
        }
        if (!parsed.ok) {
            throw new Error(`telegram refused the message: ${parsed.error_code} `
                            + scrub(parsed.description));
        }
        return parsed.result;
    }
}

// ---------------------------------------------------------------------------

class DiscordSink {
    /**
     * A webhook, not a bot token, and the difference is the whole point.
     *
     * A webhook can post to exactly one channel. It cannot read a single
     * message, cannot see the member list, cannot remove anyone, cannot touch
     * another channel. A bot token can do all of those, and an announcement
     * needs none of them -- so the worst case for a leaked webhook is somebody
     * posting nonsense in one channel, which is embarrassing and reversible,
     * rather than losing the server.
     */
    constructor({ webhookUrl, timeout = 20000, username = 'WAM Network' }) {
        if (!webhookUrl) throw new Error('discord: no webhookUrl configured');

        let parsed;
        try {
            parsed = new URL(webhookUrl);
        } catch {
            throw new Error('discord: webhookUrl is not a URL');
        }
        if (parsed.protocol !== 'https:'
            || !/^(canary\.|ptb\.)?discord(app)?\.com$/.test(parsed.hostname)
            || !parsed.pathname.startsWith('/api/webhooks/')) {
            // Refuse to post anywhere else. A mistyped or substituted URL would
            // otherwise deliver every announcement -- and the webhook itself --
            // to whoever owns that host.
            throw new Error('discord: webhookUrl is not a Discord webhook address');
        }

        this.url = parsed;
        this.timeout = timeout;
        this.username = username;
    }

    get name() { return 'discord'; }

    async send(message) {
        const res = await postJson(this.url, {
            content: fit(toDiscord(message), DISCORD_LIMIT),
            username: this.username,
            // Denied at the API, not filtered in the text. Release notes are
            // written by other people and "@everyone" in one of them would
            // otherwise notify a whole server.
            allowed_mentions: { parse: [] }
        }, this.timeout, 'discord');

        if (res.status === 429) {
            let after = '';
            try { after = ` retry after ${JSON.parse(res.text).retry_after}s`; } catch { /* shape varies */ }
            throw new Error(`discord is rate limiting this webhook${after}`);
        }
        // 204 with no body is the success case for a webhook.
        if (res.status < 200 || res.status >= 300) {
            throw new Error(`discord refused the message: HTTP ${res.status} `
                            + scrub(res.text).slice(0, 200));
        }
        return true;
    }
}

// ---------------------------------------------------------------------------

/**
 * Build the sinks a config asks for.
 *
 * A service that is not configured is simply absent -- running with Telegram
 * alone, or Discord alone, is a supported state, not a degraded one. But a
 * service that is configured and cannot be constructed throws here, at start-up,
 * rather than at the first announcement hours later.
 */
function buildSinks(cfg) {
    const sinks = [];
    if (cfg.telegram && cfg.telegram.token) sinks.push(new TelegramSink(cfg.telegram));
    if (cfg.discord && cfg.discord.webhookUrl) sinks.push(new DiscordSink(cfg.discord));
    return sinks;
}

module.exports = { TelegramSink, DiscordSink, buildSinks, scrub, fit };

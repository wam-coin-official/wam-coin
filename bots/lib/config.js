'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  config.js -- read and validate the announcement config, once
// ===========================================================================
//
//  This lived inside announce.js until say.js needed it too. It is here
//  rather than copied because of what it contains: the refusal to start
//  against a world-readable credentials file, raised by an external reviewer
//  on 2026-08-09.
//
//  A second copy of a credential check is a credential check that will
//  eventually disagree with the first one, and the copy that is wrong is the
//  one nobody looks at. Three separate faults today came from exactly that
//  shape -- two places holding the same fact, edited by different hands.
// ===========================================================================

const fs = require('fs');
const path = require('path');

function loadConfig(file) {
    if (!fs.existsSync(file)) {
        throw new Error(`config not found: ${file}\nRun bots/setup.sh to create one.`);
    }

    // This file holds channel credentials -- a Telegram token, a Discord
    // webhook, or both. Each is a password for a public channel. setup.sh
    // writes it 0600, but a config copied by hand, restored from a backup, or
    // dropped in by an editor arrives with whatever umask was in force, usually
    // world-readable.
    //
    // Refusing to start is deliberate. A warning printed at boot is read once
    // and then scrolls away for months. Raised by an external reviewer,
    // 2026-08-09.
    if (process.platform !== 'win32') {
        const mode = fs.statSync(file).mode & 0o777;
        if (mode & 0o077) {
            throw new Error(
                `${file} is mode ${mode.toString(8).padStart(3, '0')}: readable by ` +
                'other users on this machine.\n' +
                'It contains the credentials for your announcement channels.\n' +
                `Fix it with:  chmod 600 ${file}`);
        }
    }

    const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));

    if (!cfg.node) throw new Error("config is missing 'node'");

    // At least one channel, and no placeholders. A bot that starts having been
    // configured with nowhere to post looks healthy in systemd and is silent
    // for weeks before anyone notices.
    const hasTelegram = !!(cfg.telegram && cfg.telegram.token);
    const hasDiscord = !!(cfg.discord && cfg.discord.webhookUrl);
    if (!hasTelegram && !hasDiscord) {
        throw new Error('config names no channel: add telegram.token, discord.webhookUrl, or both');
    }
    for (const [where, value] of [['telegram.token', hasTelegram && cfg.telegram.token],
                                  ['discord.webhookUrl', hasDiscord && cfg.discord.webhookUrl]]) {
        if (value && String(value).includes('CHANGE_ME')) {
            throw new Error(`refusing to start with a placeholder ${where}`);
        }
    }
    if (hasTelegram && !cfg.telegram.chatId) throw new Error('config.telegram.chatId is required');

    // ?? not ||, so that a deliberate 0 survives. With || a configured
    // heartbeatHours of 0 silently becomes 24, and the operator is left
    // wondering why the setting does nothing.
    cfg.pollSeconds       = cfg.pollSeconds       ?? 60;
    cfg.heartbeatHours    = cfg.heartbeatHours    ?? 24;
    cfg.stallMinutes      = cfg.stallMinutes      ?? 60;
    cfg.githubRepo        = cfg.githubRepo        ?? null;
    cfg.stateFile         = cfg.stateFile         ?? path.join(path.dirname(file), 'announce-state.json');
    cfg.milestoneHeights  = cfg.milestoneHeights  ?? [1, 100, 1000, 10000, 50000,
                                                      100000, 200000, 400000, 500000,
                                                      1000000, 2000000, 5000000, 6600000];
    return cfg;
}

module.exports = { loadConfig };

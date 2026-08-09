'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.

const fs = require('fs');
const path = require('path');

const LEVELS = { debug: 0, info: 1, warn: 2, error: 3 };
const COLORS = { debug: '\x1b[90m', info: '\x1b[36m', warn: '\x1b[33m', error: '\x1b[31m' };
const RESET = '\x1b[0m';

class Logger {
    constructor(options = {}) {
        this.level = LEVELS[options.level || 'info'];
        this.useColor = process.stdout.isTTY && options.color !== false;
        this.stream = null;

        if (options.file) {
            fs.mkdirSync(path.dirname(options.file), { recursive: true });
            this.stream = fs.createWriteStream(options.file, { flags: 'a' });
        }
    }

    _write(level, component, message) {
        if (LEVELS[level] < this.level) return;

        const ts = new Date().toISOString().replace('T', ' ').replace('Z', '');
        const line = `${ts} [${level.toUpperCase().padEnd(5)}] [${component}] ${message}`;

        if (this.useColor) {
            console.log(`${COLORS[level]}${line}${RESET}`);
        } else {
            console.log(line);
        }
        // The file always gets the uncoloured line -- escape codes in a log file
        // that ops will grep are pure noise.
        if (this.stream) this.stream.write(line + '\n');
    }

    debug(c, m) { this._write('debug', c, m); }
    info(c, m)  { this._write('info', c, m); }
    warn(c, m)  { this._write('warn', c, m); }
    error(c, m) { this._write('error', c, m); }

    /** Bind a component name so call sites read log.info('...') */
    scope(component) {
        return {
            debug: (m) => this.debug(component, m),
            info:  (m) => this.info(component, m),
            warn:  (m) => this.warn(component, m),
            error: (m) => this.error(component, m)
        };
    }
}

module.exports = Logger;

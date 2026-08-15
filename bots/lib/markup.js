'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// One message, rendered for whichever service is carrying it.
//
// The announcement bot used to build Telegram HTML directly -- "<b>Height</b>"
// inside every message builder -- which made a second destination impossible
// without writing every message twice. Discord reads Markdown, so those same
// strings would arrive with their tags showing.
//
// Worse, escaping happened at construction: each builder had to remember to
// call Telegram.escape() on anything it did not write itself. That is a rule a
// person has to keep, in fifteen places, forever, and the failure is silent --
// a release note containing "<" quietly breaks the message or injects markup.
//
// Escaping is a property of the destination, not of the message, so it belongs
// at the boundary where the destination is known. Here a message is built from
// b(), i() and t(), which mark up meaning and nothing else; each renderer
// escapes everything that is not one of those marks, on its way out. A builder
// added next year reaches both services correctly without knowing either
// exists, and cannot forget to escape because it is never asked to.
// ---------------------------------------------------------------------------

// In-band marks. These are control characters, so they cannot collide with
// anything a human writes, and every string that enters a message is stripped
// of control characters first -- see clean() -- so they cannot be forged by
// something we did not write.
// Written as escapes, never as literal control characters. A raw 0x11 in a
// source file is invisible in every editor, does not survive a copy-paste,
// and is the first thing a well-meaning formatter or a git filter strips --
// at which point bold silently stops working and nothing fails loudly.
const B0 = '\u0011';
const B1 = '\u0012';
const I0 = '\u0013';
const I1 = '\u0014';

const MARKS = new RegExp(`[${B0}${B1}${I0}${I1}]`, 'g');

/**
 * Strip anything that could forge a mark or break a line unexpectedly.
 *
 * Newlines and tabs survive because messages use them. Everything else in the
 * control range goes: it has no legitimate place in an announcement, and it is
 * the only way an outside string -- a release title, a chain name from the
 * node -- could inject formatting.
 */
function clean(value) {
    return String(value === undefined || value === null ? '' : value)
        .replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, '');
}

/** Bold. */
function b(text) {
    return B0 + clean(text) + B1;
}

/** Italic. */
function i(text) {
    return I0 + clean(text) + I1;
}

/**
 * Plain text from somewhere other than this codebase.
 *
 * Interpolating a literal we wrote is fine without this. Anything that came
 * from the node, from GitHub, or from a config file goes through here -- not
 * to escape it, which happens later per destination, but so it cannot carry
 * marks of its own.
 */
function t(text) {
    return clean(text);
}

/**
 * Walk a message, handing plain runs to `escape` and marks to `open`/`close`.
 *
 * Shared by both renderers so they cannot disagree about what a mark means, or
 * about which parts of a message count as text.
 */
function render(message, { escape, bold, italic }) {
    let out = '';
    let plain = '';

    const flush = () => { out += escape(plain); plain = ''; };

    for (const ch of String(message)) {
        switch (ch) {
        case B0: flush(); out += bold[0]; break;
        case B1: flush(); out += bold[1]; break;
        case I0: flush(); out += italic[0]; break;
        case I1: flush(); out += italic[1]; break;
        default: plain += ch;
        }
    }
    flush();
    return out;
}

/** Telegram's HTML parse mode: only &, < and > are special. */
function toTelegram(message) {
    return render(message, {
        escape: (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'),
        bold: ['<b>', '</b>'],
        italic: ['<i>', '</i>']
    });
}

/**
 * Discord Markdown.
 *
 * Exactly the characters Discord treats as formatting anywhere in a line, and
 * no others. The set was wider once and that was a mistake in the visible
 * direction: Discord consumes a backslash only in front of a character it
 * considers special, and prints both when it does not. Escaping '+' turned
 * every heartbeat into "47.50 miner \+ 2.50 treasury" on Discord while the
 * same line was correct on Telegram -- the exact failure the neutral markup
 * exists to prevent, arriving through the renderer instead.
 *
 * Left alone deliberately: '>', '#' and '-', which mean something to Discord
 * only at the start of a line. A release note that begins a line with one of
 * them becomes a quote, a heading or a bullet, which is how its author wrote
 * it and is no more than cosmetic. They cannot close a mark or execute
 * anything, and escaping them mid-line is what produced the visible junk.
 */
function toDiscord(message) {
    return render(message, {
        escape: (s) => s
            // Special on their own: one asterisk or underscore is italic, one
            // backtick is code, and a backslash escapes whatever follows it.
            .replace(/([\\*_`])/g, '\\$1')
            // Special only in pairs. A lone tilde is a tilde -- "~275 days"
            // appears in every heartbeat and had been arriving as "\~275".
            // A lone pipe is a pipe.
            .replace(/~~/g, '\\~\\~')
            .replace(/\|\|/g, '\\|\\|'),
        bold: ['**', '**'],
        italic: ['*', '*']
    });
}

/** Marks removed entirely -- for logs, which want neither markup nor escapes. */
function toPlain(message) {
    return String(message).replace(MARKS, '');
}

module.exports = { b, i, t, clean, toTelegram, toDiscord, toPlain };

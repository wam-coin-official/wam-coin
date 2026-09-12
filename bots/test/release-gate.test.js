'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// The bot announced a release that did not verify, sixty-one seconds after it
// was published.
//
// 12 September 2026. v0.1.8 was the first release carrying Windows archives,
// which are added to the page by hand. SHA256SUMS.asc was uploaded and
// SHA256SUMS was not replaced -- so the signature covered a four-line list
// while the page still carried the runner's two-line one. The bot posted to
// Telegram at 05:44:42 and Discord at 05:44:43. Published at 05:44:23.
//
// For as long as that stood, a stranger following this project's own
// instructions was told:
//
//     FAIL  the signature over SHA256SUMS is NOT valid
//           SHA256SUMS was changed after it was signed, or the signature is
//           not ours. Do not run the binaries.
//
// Which is the verifier working perfectly, and is the worst sentence a coin
// project can put in front of somebody deciding whether to trust it.
//
// The bot was not at fault: announcing is its job. The fault was that nothing
// verified the release before it spoke, and check_release_signed.sh -- whose
// own header has said since the day it was written that "uploading is a manual
// step and manual steps get half-done" -- ran only when a person happened to
// run the sweep.
//
// These tests exist because "the bot now checks first" is a claim, and a claim
// about a guard is worth nothing until the guard has been watched refusing.
// ---------------------------------------------------------------------------

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { verifyPublishedRelease } = require('../announce');

let pass = 0;
const fail = [];

function test(name, fn) {
    try { fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

/** A stand-in for check_release_signed.sh that exits how the test wants. */
function fakeCheck(dir, code, output) {
    const p = path.join(dir, `check-${code}.sh`);
    fs.writeFileSync(p, `#!/bin/bash\ncat <<'EOF'\n${output}\nEOF\nexit ${code}\n`);
    return p;
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'wam-gate-'));

console.log('\n=== nothing is announced about a release that does not verify ===');

test('exit 0 is the only thing that counts as verified', () => {
    const s = fakeCheck(tmp, 0, '  ok    SHA256SUMS.asc verifies');
    const r = verifyPublishedRelease('v0.1.8', s);
    assert.strictEqual(r.ok, true, 'a passing check must return ok');
});

test('exit 1 -- published and does not verify -- is refused', () => {
    const s = fakeCheck(tmp, 1,
        '  FAIL  the signature over SHA256SUMS is NOT valid');
    const r = verifyPublishedRelease('v0.1.8', s);
    assert.strictEqual(r.ok, false, 'a failing check must not return ok');
    assert.ok(/NOT valid/.test(r.reason),
        `the script's own words must survive into the reason, got: ${r.reason}`);
});

test('exit 2 -- the check could not run -- is not a pass', () => {
    // The distinction this whole project turns on. A host with no gpg, or
    // GitHub unreachable, must not read as "verified" and must not read as
    // "the release is broken" either.
    const s = fakeCheck(tmp, 2, '  !!    gpg is not installed');
    const r = verifyPublishedRelease('v0.1.8', s);
    assert.strictEqual(r.ok, false, 'exit 2 must not be treated as verified');
    assert.ok(/could not run/i.test(r.reason),
        `exit 2 must say it could not run, got: ${r.reason}`);
});

test('a missing check script is refused, not ignored', () => {
    // If the script is gone -- a bad deploy, a renamed file -- the bot must
    // not fall back to announcing. Silence that somebody notices is better
    // than a release nobody verified.
    const r = verifyPublishedRelease('v0.1.8', path.join(tmp, 'does-not-exist.sh'));
    assert.strictEqual(r.ok, false);
    assert.ok(/not at/.test(r.reason), `got: ${r.reason}`);
});

test('a check that hangs does not hang the bot', () => {
    const s = path.join(tmp, 'hang.sh');
    fs.writeFileSync(s, '#!/bin/bash\nsleep 600\n');
    const started = Date.now();
    // The real timeout is 180s; this only has to prove the call is bounded
    // and that a timeout is reported as "not verified" rather than thrown.
    const r = verifyPublishedRelease('v0.1.8', s);
    const took = Date.now() - started;
    assert.strictEqual(r.ok, false, 'a timeout must not read as verified');
    assert.ok(took < 200000, `the call must be bounded, took ${took}ms`);
});

console.log(`\n  ${pass} passed, ${fail.length} failed\n`);
fs.rmSync(tmp, { recursive: true, force: true });
process.exit(fail.length === 0 ? 0 : 1);

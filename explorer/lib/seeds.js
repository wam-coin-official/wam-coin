'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  seeds.js -- how many DNS seeds this network has, and how many answer
// ===========================================================================
//
//  WHY THIS EXISTS
//
//  The network panel used to count seeds among this node's peers, which can
//  never include the machine it runs on. Served from the France seed it saw
//  Singapore and nothing else, and the page said "WAM seed nodes: 1" -- read
//  by a visitor as a network with a single point of failure, when there are
//  two.
//
//  Relabelling it "other WAM seeds reached" made the number honest, and left
//  the question a visitor actually has unanswered: how many seeds does this
//  network have, and are they up?
//
//  So this asks DNS, which is the same thing a new node asks before it has
//  any peers at all. No self-knowledge is involved and nothing is guessed: a
//  seed either resolves and accepts a connection or it does not.
//
//  WHY THE ADDRESSES ARE COUNTED AND NOT THE NAMES
//
//  seed1, seed2 and seed3 all resolve to the same two machines today. Three
//  names on two hosts is not three seeds, and a page about decentralisation
//  that counted names would be flattering itself. Distinct addresses that
//  answer is the number that means something, and it becomes 3 on its own
//  the day a third machine exists -- no code changes.
//
//  NO ADDRESS IS EVER RETURNED. Only counts and, for our own seeds, the
//  country. A list of who runs a node is a list of who to attack.
// ===========================================================================

const dns = require('dns').promises;
const net = require('net');

// x9 = NODE_NETWORK | NODE_WITNESS. Bitcoin Core asks for a service-bit
// prefix rather than the bare name, and the bare name has no A record at
// all -- checking it would report a working seed as broken.
const PREFIX = 'x9';

const DEFAULT_SEEDS = ['seed1.wamcoin.org', 'seed2.wamcoin.org', 'seed3.wamcoin.org'];

const P2P_PORT = { main: 9555, test: 19555, regtest: 29555 };

// Places we already publish for our own machines. Anything else stays
// unnamed: this is a public page.
const PLACES = {
    '169.58.159.165': 'France',
    '5.223.52.200': 'Singapore'
};

function reachable(host, port, timeoutMs) {
    return new Promise((resolve) => {
        const s = new net.Socket();
        let done = false;
        const finish = (ok) => {
            if (done) return;
            done = true;
            s.destroy();
            resolve(ok);
        };
        s.setTimeout(timeoutMs);
        s.once('connect', () => finish(true));
        s.once('timeout', () => finish(false));
        s.once('error', () => finish(false));
        s.connect(port, host);
    });
}

class Seeds {
    /**
     * @param {object} opts
     *   hostnames  seed names without the x9. prefix
     *   chain      'main' | 'test' | 'regtest', from getblockchaininfo
     *   ttlMs      how long an answer is reused. A seed does not come and go
     *              minute to minute, and a page refresh must not cost a DNS
     *              query and three TCP connects.
     */
    constructor(opts = {}) {
        this.hostnames = opts.hostnames || DEFAULT_SEEDS;
        this.chain = opts.chain || 'test';
        this.ttlMs = opts.ttlMs || 5 * 60 * 1000;
        this.timeoutMs = opts.timeoutMs || 4000;
        this.last = null;
        this.checkedAt = 0;
        this.inFlight = null;
    }

    setChain(chain) {
        if (chain && chain !== this.chain) {
            this.chain = chain;
            this.last = null;          // a different port entirely
            this.checkedAt = 0;
        }
    }

    /** The cached answer, refreshing it in the background when stale. */
    snapshot() {
        const age = Date.now() - this.checkedAt;
        if (!this.inFlight && (this.last === null || age > this.ttlMs)) {
            // Deliberately not awaited. The first page load after a restart
            // gets `null`, which the front end renders as an em dash, and the
            // one after it gets the answer. A dashboard that blocks on the
            // network is a dashboard that hangs when the network is the thing
            // that is broken.
            this.inFlight = this.probe()
                .then((r) => { this.last = r; this.checkedAt = Date.now(); })
                .catch(() => { /* keep the previous answer */ })
                .finally(() => { this.inFlight = null; });
        }
        return this.last;
    }

    async probe() {
        const port = P2P_PORT[this.chain] || P2P_PORT.test;

        const byAddress = new Map();     // address -> { names:Set }
        let resolved = 0;

        for (const name of this.hostnames) {
            let addrs = [];
            try {
                addrs = await dns.resolve4(`${PREFIX}.${name}`);
            } catch {
                addrs = [];
            }
            if (addrs.length) resolved += 1;
            for (const a of addrs) {
                if (!byAddress.has(a)) byAddress.set(a, new Set());
                byAddress.get(a).add(name);
            }
        }

        const addresses = [...byAddress.keys()];
        const results = await Promise.all(
            addresses.map((a) => reachable(a, port, this.timeoutMs)));

        const up = [];
        for (let i = 0; i < addresses.length; i++) {
            if (results[i]) up.push(addresses[i]);
        }

        return {
            // The numbers that mean something.
            machines: addresses.length,
            answering: up.length,
            // Names are reported only as a count: three names on two machines
            // is a fact about DNS, not about the network.
            hostnames: this.hostnames.length,
            hostnamesResolving: resolved,
            port,
            // Countries for the ones we publish anyway, in a stable order.
            places: up.map((a) => PLACES[a]).filter(Boolean).sort(),
            checkedAt: Date.now()
        };
    }
}

module.exports = { Seeds, DEFAULT_SEEDS, PLACES, PREFIX };

'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// What the network looks like from here.
//
// The pool dashboard answers "is anyone mining with me". This answers a
// different and, at launch, a more important question: is this a network, or
// one person's laptop? The measure of that is not hashrate -- it is how many
// independent machines validate the chain for themselves, because a node
// operator is someone who has chosen not to trust anybody, including us.
//
// WHAT IS NOT PUBLISHED, AND WHY
//
// No addresses. Not truncated, not hashed, not "just the first two octets".
// Someone running a WAM node is doing us a favour, and publishing where they
// are turns that into a target list -- for a denial-of-service, for an eclipse
// attempt, or for whoever objects to the software in their country. The one
// thing this page exists to celebrate is the one thing it must not expose.
//
// No geolocation either, which was the original plan. Resolving a country
// means sending every peer's address to a third-party service, which is the
// same disclosure wearing a different coat. Our own seeds are the exception:
// their addresses are already in public DNS, we chose to publish them, and
// nobody else's privacy is ours to spend.
//
// What is left -- counts, versions, direction, how long connections have held
// -- is enough to see the network grow and gives an observer nothing to aim at.
// ---------------------------------------------------------------------------

// Our own seeds. Published in DNS already, so naming them costs nobody
// anything and lets a reader see the network is not all in one place.
const OWN_SEEDS = {
    '169.58.159.165': { label: 'seed', where: 'France' },
    '5.223.52.200':   { label: 'seed', where: 'Singapore' }
};

/**
 * Split "host:port" into the host, for the three shapes a peer address takes.
 *
 * Getting this wrong is not cosmetic: an onion address carries a port too, so
 * testing the whole string for a .onion suffix never matches and every Tor
 * peer is silently counted as IPv4 -- which would misreport the one statistic
 * that says whether anyone values their privacy on this network.
 */
function hostOf(addr) {
    const s = String(addr || '');
    if (s.startsWith('[')) return s.slice(1).split(']')[0];   // [2001:db8::1]:19555
    const colons = (s.match(/:/g) || []).length;
    if (colons > 1) return s;                                  // bare IPv6, no port
    return s.split(':')[0];                                    // 1.2.3.4:19555, x.onion:19555
}

/** Reduce an address to something countable but not locatable. */
function classify(addr) {
    const host = hostOf(addr);
    if (OWN_SEEDS[host]) return { kind: 'seed', ...OWN_SEEDS[host], host };
    if (/\.onion$/i.test(host)) return { kind: 'onion' };
    if (host.includes(':')) return { kind: 'ipv6' };
    return { kind: 'ipv4' };
}

/**
 * Build the public view.
 *
 * `peers` is getpeerinfo; `known` is getnodeaddresses, which is the node's
 * whole address book rather than only what it is connected to right now. The
 * second number is the honest one for "how big is this network": a node holds
 * addresses it learned from others and has never dialled.
 */
function build(peers, known, netInfo) {
    const list = Array.isArray(peers) ? peers : [];

    // Keyed by place, not by connection. Two nodes routinely hold a pair of
    // connections to each other -- one dialled each way -- and listing
    // "Singapore, Singapore" makes one seed look like two, which is the
    // opposite of what a page about decentralisation should do.
    //
    // This counts seeds among this node's PEERS, so it can never include the
    // machine it runs on. Served from the France seed it reports Singapore
    // and nothing else, and the page used to label that "WAM seed nodes: 1"
    // -- which a reader takes as "this network has one seed", a single point
    // of failure, when there are two.
    //
    // The label now reads "other WAM seeds reached", so the number means what
    // it counts. Do not make it self-aware instead: a node deciding whether
    // it is itself a seed is a guess, and a wrong guess here overstates the
    // network rather than understating it.
    const seedsByPlace = new Map();
    const counts = { ipv4: 0, ipv6: 0, onion: 0, seed: 0 };
    const versions = new Map();
    let inbound = 0;
    let longest = 0;

    for (const p of list) {
        const c = classify(p.addr);
        counts[c.kind] = (counts[c.kind] || 0) + 1;

        if (c.kind === 'seed') {
            const held = p.conntime
                ? Math.max(0, Math.floor(Date.now() / 1000 - p.conntime)) : null;
            const prev = seedsByPlace.get(c.where);
            seedsByPlace.set(c.where, {
                where: c.where,
                connections: (prev ? prev.connections : 0) + 1,
                version: p.subver || (prev ? prev.version : null),
                // The longest-held of the pair: how long this link has
                // actually stood, not how long its newest strand has.
                connectedSeconds: Math.max(prev ? prev.connectedSeconds || 0 : 0, held || 0)
            });
        }

        if (p.inbound) inbound++;
        if (p.subver) versions.set(p.subver, (versions.get(p.subver) || 0) + 1);

        const held = p.conntime ? Math.floor(Date.now() / 1000 - p.conntime) : 0;
        if (held > longest) longest = held;
    }

    return {
        // Connected right now, from this node's point of view. A node behind a
        // home router shows as inbound here because it dialled out to us --
        // which is why "inbound" is not the same as "someone else's server".
        connected: list.length,
        inbound,
        outbound: list.length - inbound,

        // Addresses this node has learned of, whether or not it has ever
        // spoken to them. The closest thing to a network size we can report
        // without crawling, and it does not require anyone to be online now.
        known: Array.isArray(known) ? known.length : null,

        byType: counts,
        versions: [...versions.entries()]
            .map(([version, count]) => ({ version, count }))
            .sort((a, b) => b.count - a.count),

        // Ours, named, because they are already public. One entry per place.
        seeds: [...seedsByPlace.values()].sort((a, b) => a.where.localeCompare(b.where)),

        longestConnectionSeconds: longest,

        // Said in the payload rather than only in the page, so anyone reading
        // the API sees the policy too.
        privacy: 'Peer addresses are never published. Only WAM\'s own seed nodes, '
               + 'which are already listed in public DNS, are named.'
    };
}

module.exports = { build, classify, OWN_SEEDS };

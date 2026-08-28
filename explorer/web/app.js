'use strict';
/* WAM Network Dashboard
   Copyright (c) 2026 The WAM Coin developers -- MIT

   Polls /api/status and repaints. Dependency-free: the page that tells you the
   node is down must not itself depend on a CDN being up.

   Every value that came off the wire is written with textContent, never
   innerHTML. Block hashes and node subversion strings are attacker-influenced. */

const COIN = 1e8;
const REFRESH_MS = 6000;

const $ = (id) => document.getElementById(id);
const text = (el, v) => { if (el) el.textContent = v; };

// ---------------------------------------------------------------- format

function wam(sat, dp = 2) {
  if (sat === null || sat === undefined) return '—';

  // Two decimals is right for ordinary amounts and a lie for small ones: deep
  // into the halvings a block reward of 74 satoshi renders as "0.00 WAM",
  // which reads as "nothing" rather than "something small". Widen rather than
  // round away a number someone is checking.
  if (sat !== 0 && Math.abs(sat) < COIN / 10 ** dp) {
    return (sat / COIN).toFixed(8).replace(/0+$/, '').replace(/\.$/, '');
  }

  return (sat / COIN).toLocaleString('en-US',
    { minimumFractionDigits: dp, maximumFractionDigits: dp });
}

function hashrate(hs) {
  if (!hs || hs <= 0) return '0 H/s';
  const u = ['H/s', 'kH/s', 'MH/s', 'GH/s', 'TH/s', 'PH/s'];
  let i = 0;
  while (hs >= 1000 && i < u.length - 1) { hs /= 1000; i++; }
  return `${hs.toFixed(hs < 10 ? 2 : 1)} ${u[i]}`;
}

function bytes(n) {
  if (!n) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(n < 10 ? 1 : 0)} ${u[i]}`;
}

function duration(sec) {
  if (sec === null || sec === undefined || !isFinite(sec)) return '—';
  sec = Math.round(sec);
  if (sec < 60) return `${sec}s`;
  if (sec < 3600) return `${Math.floor(sec / 60)}m`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h ${Math.floor((sec % 3600) / 60)}m`;
  const d = Math.floor(sec / 86400);
  if (d < 60) return `${d}d`;
  const mo = d / 30.44;
  return mo < 24 ? `${mo.toFixed(1)} months` : `${(d / 365.25).toFixed(1)} years`;
}

function ago(unixSec) {
  if (!unixSec) return '—';
  return duration(Date.now() / 1000 - unixSec) + ' ago';
}

function utcDate(unixSec) {
  if (!unixSec) return '—';
  return new Date(unixSec * 1000).toISOString().slice(0, 10);
}

function cell(row, value, cls) {
  const td = document.createElement('td');
  td.textContent = value;
  if (cls) td.className = cls;
  row.appendChild(td);
  return td;
}

function emptyRow(tbody, cols, msg) {
  tbody.replaceChildren();
  const tr = document.createElement('tr');
  const td = document.createElement('td');
  td.colSpan = cols; td.className = 'empty'; td.textContent = msg;
  tr.appendChild(td); tbody.appendChild(tr);
}

async function getJSON(path) {
  const res = await fetch(path, { cache: 'no-store' });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

// ---------------------------------------------------------------- render

function renderNodeState(s) {
  const pill = $('nodePill');
  const banner = $('banner');
  pill.classList.remove('ok', 'bad', 'warn');
  banner.classList.add('hidden');
  banner.classList.remove('warn');

  if (!s.nodeOnline) {
    pill.classList.add('bad');
    text($('nodeText'), 'node offline');
    banner.classList.remove('hidden');
    text(banner, `Cannot reach wamd: ${s.error || 'unknown error'}` +
      (s.updatedAt ? ` — showing data from ${duration(s.staleSeconds)} ago.` : ''));
    return;
  }

  // A syncing node reports real numbers about a stale tip. Say so, loudly:
  // every figure below is about the past until this clears.
  if (s.chain && s.chain.syncing) {
    pill.classList.add('warn');
    text($('nodeText'), `syncing — ${s.chain.blocksBehind.toLocaleString()} behind`);
    banner.classList.remove('hidden');
    banner.classList.add('warn');
    const pct = s.chain.verificationProgress !== undefined
      ? ` (${(s.chain.verificationProgress * 100).toFixed(2)}% verified)` : '';
    text(banner, `This node is still syncing${pct}. Every figure below describes ` +
      'the chain up to its current tip, not the network head.');
    return;
  }

  pill.classList.add('ok');
  text($('nodeText'), `synced · updated ${s.staleSeconds}s ago`);
}

function renderTiles(s) {
  const c = s.chain, e = s.emission, sup = s.supply;
  if (!c) return;

  text($('tHeight'), c.blocks.toLocaleString());
  text($('tHeightNote'), c.bestBlockHash
    ? `tip ${c.bestBlockHash.slice(0, 10)}…` : '');

  text($('tHashrate'), hashrate(c.networkHashPerSecond));
  text($('tDifficulty'), `difficulty ${Number(c.difficulty || 0)
    .toLocaleString(undefined, { maximumFractionDigits: 2 })}`);

  if (sup) {
    text($('tSupply'), `${wam(sup.circulating, 0)} WAM`);
    text($('tSupplyNote'), `${(sup.percentMined || 0).toFixed(2)}% of 22,000,000`);
  }

  if (e) {
    text($('tReward'), `${wam(e.subsidy, 2)} WAM`);
    text($('tRewardNote'), e.treasurySubsidy > 0
      ? `${wam(e.minerSubsidy, 2)} miner + ${wam(e.treasurySubsidy, 2)} treasury`
      : `${wam(e.minerSubsidy, 2)} to miner — 100%`);

    text($('tHalving'), duration(e.secondsUntilHalving));
    text($('tHalvingNote'),
      `${e.blocksUntilHalving.toLocaleString()} blocks → ${wam(e.subsidy / 2, 2)} WAM`);
  }

  text($('tPeers'), c.connections !== null && c.connections !== undefined
    ? String(c.connections) : '—');
  text($('tMempool'), s.mempool
    ? `${s.mempool.transactions} tx in mempool` : '');
}

function renderSupply(s) {
  const sup = s.supply;
  if (!sup) return;

  const max = sup.maxSupply;
  const v = sup.vesting || { unlocked: 0, locked: 0, total: 0 };

  // Circulating includes the whole premine, so the publicly mined portion is
  // circulating minus the premine. Showing the premine inside "mined" would
  // overstate what miners actually produced.
  const mined = Math.max(0, sup.circulating - sup.premine);
  const unmined = Math.max(0, max - sup.circulating);

  const pct = (x) => `${(100 * x / max).toFixed(4)}%`;
  $('segMined').style.width = pct(mined);
  $('segVested').style.width = pct(v.unlocked);
  $('segLocked').style.width = pct(v.locked);
  $('segUnmined').style.width = pct(unmined);

  text($('sMined'), `${wam(mined, 0)} WAM`);
  text($('sVested'), `${wam(v.unlocked, 0)} WAM`);
  text($('sLocked'), `${wam(v.locked, 0)} WAM`);
  text($('sUnmined'), `${wam(unmined, 0)} WAM`);
  text($('sMax'), `${wam(max, 0)} WAM`);

  text($('supplySource'), sup.source === 'node'
    ? 'Figures come from the node\'s own getsupplyinfo, i.e. from consensus code.'
    : 'This node does not expose getsupplyinfo; figures are recomputed by the ' +
      'dashboard from the same constants.');
}

function renderVesting(s) {
  const tbody = $('vestTable').querySelector('tbody');
  const v = s.supply && s.supply.vesting;
  if (!v || !v.schedule || !v.schedule.length) {
    return emptyRow(tbody, 4, 'no vesting data');
  }

  tbody.replaceChildren();
  for (const t of v.schedule) {
    const tr = document.createElement('tr');
    cell(tr, String(t.tranche));
    cell(tr, `${wam(t.amount, 0)} WAM`, 'num');
    cell(tr, t.unlockTime === 0 ? 'genesis' : utcDate(t.unlockTime));

    const td = document.createElement('td');
    const badge = document.createElement('span');
    badge.className = `badge ${t.unlocked ? 'ok' : 'warn'}`;
    badge.textContent = t.unlocked ? 'unlocked' : 'locked';
    td.appendChild(badge);
    tr.appendChild(td);
    tbody.appendChild(tr);
  }
}

function renderTreasury(s) {
  const t = s.treasury;
  if (!t) return;

  text($('trStatus'), t.active ? 'collecting' : 'ended');
  text($('trPercent'), t.active ? `${t.percent}%` : '0% (expired)');
  text($('trEnd'), t.lastHeight.toLocaleString());
  text($('trRemaining'), t.active
    ? `${t.blocksRemaining.toLocaleString()} (~${duration(t.secondsRemaining)})`
    : 'miners now take 100%');
}

function renderRandomX(s) {
  const rx = s.randomx;
  if (!rx) {
    text($('rxSeedHeight'), 'unavailable');
    text($('rxSeedHash'), 'node lacks getrandomxinfo');
    return;
  }
  text($('rxSeedHeight'), rx.bootstrap ? 'bootstrap epoch'
    : rx.seedHeight.toLocaleString());
  text($('rxSeedHash'), rx.seedHash || '—');
  $('rxSeedHash').title = rx.seedHash || '';
  text($('rxEpoch'), `${rx.epochBlocks.toLocaleString()} blocks (lag ${rx.epochLag})`);
  text($('rxRotation'), `${rx.blocksUntilRotation} blocks (~${duration(rx.secondsUntilRotation)})`);
  text($('rxMemory'), bytes(rx.memoryBytes));
}

function renderBlocks(blocks) {
  const tbody = $('blocksTable').querySelector('tbody');
  if (!blocks || !blocks.length) return emptyRow(tbody, 6, 'no blocks yet');

  tbody.replaceChildren();
  for (const b of blocks) {
    const tr = document.createElement('tr');
    cell(tr, b.height.toLocaleString());
    cell(tr, ago(b.time));
    cell(tr, String(b.txCount ?? '—'), 'num');
    cell(tr, bytes(b.size), 'num');
    cell(tr, Number(b.difficulty || 0).toLocaleString(undefined,
      { maximumFractionDigits: 2 }), 'num');

    const td = document.createElement('td');
    const span = document.createElement('span');
    span.className = 'mono trunc';
    span.textContent = b.hash;
    span.title = b.hash;
    td.appendChild(span);
    tr.appendChild(td);
    tbody.appendChild(tr);
  }
}

// ---------------------------------------------------------------- forms

$('searchForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const out = $('searchResult');
  out.classList.remove('hidden');
  out.replaceChildren();

  const q = $('searchInput').value.trim();
  if (!q) return;

  try {
    const r = await getJSON(`/api/search?q=${encodeURIComponent(q)}`);
    const h = document.createElement('p');
    h.textContent = r.type === 'block'
      ? `Block ${r.data.height?.toLocaleString() ?? ''}`
      : 'Transaction';
    h.style.fontWeight = '650';
    out.appendChild(h);

    const pre = document.createElement('pre');
    pre.textContent = JSON.stringify(r.data, null, 2);
    out.appendChild(pre);
  } catch (err) {
    const p = document.createElement('p');
    p.className = 'err';
    p.textContent = err.message;
    out.appendChild(p);
  }
});

$('auditForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const out = $('auditResult');
  out.classList.remove('hidden');
  out.replaceChildren();

  const q = $('auditInput').value.trim();
  if (!q) return;

  try {
    const r = await getJSON(`/api/audit?block=${encodeURIComponent(q)}`);
    const b = r.block;

    const table = document.createElement('table');
    table.className = 'kv';
    const rows = [
      ['Height', b.height.toLocaleString()],
      ['Block subsidy', `${b.subsidy} WAM`],
      ['Treasury required', `${b.required} WAM`],
      ['Treasury paid', `${b.paid} WAM`],
      ['Treasury address', r.address || '—']
    ];
    for (const [k, val] of rows) {
      const tr = document.createElement('tr');
      cell(tr, k); cell(tr, String(val), 'num');
      table.appendChild(tr);
    }
    out.appendChild(table);

    const verdict = document.createElement('p');
    const badge = document.createElement('span');
    badge.className = `badge ${b.compliant ? 'ok' : 'bad'}`;
    badge.textContent = b.compliant
      ? 'COMPLIANT — consensus rule WAM-1 satisfied'
      : 'NON-COMPLIANT — this block underpaid the treasury';
    verdict.appendChild(badge);
    out.appendChild(verdict);
  } catch (err) {
    const p = document.createElement('p');
    p.className = 'err';
    p.textContent = err.message;
    out.appendChild(p);
  }
});

// ---------------------------------------------------------------- loop

// ---------------------------------------------------------------- network

// Fetched on its own rather than folded into /api/status, because the status
// payload is a cached snapshot and this is the number a visitor refreshes to
// watch. A minute-old peer count reads as a dead network.
//
// A failure here must not blank the rest of the page: the network card is the
// least important thing on it and the chain data is the most.
async function renderNetwork() {
  let n;
  try {
    n = await getJSON('/api/network');
  } catch {
    text($('netKnown'), '—');
    text($('netConnected'), '—');
    return;
  }

  text($('netKnown'), n.known === null ? '—' : n.known.toLocaleString());
  text($('netConnected'), n.connected.toLocaleString());
  text($('netInOut'), `${n.outbound} out · ${n.inbound} in`);

  // Measured from DNS, the way a node with no peers finds the network --
  // so it includes the machine serving this page, which counting peers
  // never could. That is why the panel used to say one seed when there
  // were two.
  //
  // A null snapshot is the first load after a restart, before the probe
  // has come back. An em dash is the honest thing to show then; a zero
  // would say the network has no seeds.
  const sn = n.seedNodes;
  if (sn && typeof sn.answering === 'number') {
    text($('netSeeds'), String(sn.answering));
    const parts = [];
    if (sn.answering < sn.machines) {
      parts.push(`${sn.answering} of ${sn.machines} answering`);
    }
    if (sn.places && sn.places.length) parts.push(sn.places.join(' · '));
    text($('netSeedWhere'), parts.join(' — ') || 'none answering');
  } else if (sn === null || sn === undefined) {
    text($('netSeeds'), '—');
    text($('netSeedWhere'), 'checking');
  } else {
    // Older server, or the probe is unavailable: fall back to the peer
    // count rather than showing nothing, and say what it is counting.
    text($('netSeeds'), String((n.seeds || []).length));
    text($('netSeedWhere'), (n.seeds || []).length
      ? `${n.seeds.map((s) => s.where).join(' · ')} (peers only)`
      : 'none reachable');
  }

  const t = n.byType || {};
  text($('netIpv4'), String(t.ipv4 || 0));
  text($('netIpv6'), String(t.ipv6 || 0));
  text($('netOnion'), String(t.onion || 0));

  text($('netVersions'), n.versions.length
    ? n.versions.map((v) => `${v.version} ×${v.count}`).join('  ')
    : '—');

  text($('netLongest'), n.longestConnectionSeconds
    ? duration(n.longestConnectionSeconds)
    : '—');
}

async function refresh() {
  try {
    const s = await getJSON('/api/status');

    renderNodeState(s);
    if (s.chain) {
      text($('chainLine'),
        `${s.chain.name} · height ${s.chain.blocks.toLocaleString()} · ` +
        `${s.chain.pruned ? 'pruned' : bytes(s.chain.sizeOnDisk)} on disk`);
    }
    renderTiles(s);
    renderSupply(s);
    renderVesting(s);
    renderTreasury(s);
    renderRandomX(s);
    renderBlocks(s.blocks);
    renderNetwork();

    text($('footerStatus'), `dashboard up ${duration(s.serverUptimeSec)}`);
  } catch (err) {
    const pill = $('nodePill');
    pill.classList.remove('ok', 'warn');
    pill.classList.add('bad');
    text($('nodeText'), 'dashboard API unreachable');
    const banner = $('banner');
    banner.classList.remove('hidden');
    text(banner, `Cannot reach the dashboard server: ${err.message}`);
  }
}

refresh();
setInterval(refresh, REFRESH_MS);

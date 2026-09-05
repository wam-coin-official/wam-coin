'use strict';
/* WAM Coin pool dashboard
   Copyright (c) 2026 The WAM Coin developers -- MIT

   Polls the read-only JSON API and repaints. Deliberately dependency-free:
   the dashboard is the first thing an operator loads when something is wrong,
   so it must not depend on a CDN being reachable. */

const COIN = 1e8;
const REFRESH_MS = 8000;

// ---------------------------------------------------------------- helpers

const $ = (id) => document.getElementById(id);

function hashrate(hs) {
  if (!hs || hs <= 0) return '0 H/s';
  const units = ['H/s', 'kH/s', 'MH/s', 'GH/s', 'TH/s', 'PH/s'];
  let i = 0;
  while (hs >= 1000 && i < units.length - 1) { hs /= 1000; i++; }
  return `${hs.toFixed(hs < 10 ? 2 : 1)} ${units[i]}`;
}

function wam(baseUnits, dp = 8) {
  if (baseUnits === null || baseUnits === undefined) return '—';
  return (baseUnits / COIN).toLocaleString('en-US',
    { minimumFractionDigits: dp, maximumFractionDigits: dp });
}

function duration(sec) {
  if (sec === null || sec === undefined || !isFinite(sec)) return '—';
  sec = Math.round(sec);
  if (sec < 60) return `${sec}s`;
  if (sec < 3600) return `${Math.floor(sec / 60)}m ${sec % 60}s`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h ${Math.floor((sec % 3600) / 60)}m`;
  return `${Math.floor(sec / 86400)}d ${Math.floor((sec % 86400) / 3600)}h`;
}

function ago(ms) {
  if (!ms) return '—';
  return duration((Date.now() - ms) / 1000) + ' ago';
}

/** Always set text, never innerHTML, for anything that came off the wire. */
function text(el, value) { el.textContent = value; }

function cell(row, value, cls) {
  const td = document.createElement('td');
  td.textContent = value;
  if (cls) td.className = cls;
  row.appendChild(td);
  return td;
}

function emptyRow(tbody, cols, message) {
  tbody.replaceChildren();
  const tr = document.createElement('tr');
  const td = document.createElement('td');
  td.colSpan = cols;
  td.className = 'empty';
  td.textContent = message;
  tr.appendChild(td);
  tbody.appendChild(tr);
}

async function getJSON(path) {
  const res = await fetch(path, { cache: 'no-store' });
  if (!res.ok) throw new Error(`${path} -> HTTP ${res.status}`);
  return res.json();
}

// ------------------------------------------------------------------ render

function renderStats(s) {
  const pool = s.pool || {};
  const net = s.network || {};

  text($('chainLabel'),
    `${net.chain || '?'} · block ${(net.blocks || 0).toLocaleString()} · ` +
    `${(s.config && s.config.rewardMode || '').toUpperCase()} · ` +
    `pool fee ${s.config ? s.config.poolFeePercent : '?'}% + 5% treasury`);

  text($('poolHashrate'), hashrate(pool.hashrate));
  text($('poolShare'), pool.poolSharePercent
    ? `${pool.poolSharePercent.toFixed(3)}% of network`
    : 'no shares in window');

  text($('minerCount'), String(pool.miners ?? 0));
  text($('workerCount'), `${pool.workers ?? 0} active worker${pool.workers === 1 ? '' : 's'}`);

  // The hashrate is an estimate from recent block times, so it lags badly the
  // moment blocks stop. A tester shut every miner down on 5 September and this
  // tile read 24.3 kH/s beside "0 active workers", with the chain frozen for
  // half an hour. The age of the tip cannot lag -- it is the clock minus the
  // block header -- so it is shown next to the estimate, and says plainly when
  // the estimate has stopped meaning anything.
  const stale = net.secondsSinceBlock != null && net.secondsSinceBlock > 600;
  text($('netHashrate'), hashrate(net.networkHashPerSecond));
  // Two decimal places round WAM's difficulty to "0". At the floor it is
  // 0.00024414, and the floor is exactly when somebody is reading this tile
  // to find out what happened -- the page said "difficulty 0" on the evening
  // a tester watched the chain fall to minimum. Significant digits instead of
  // decimal places, so a small number stays a number and a large one does not
  // grow a tail.
  const d = net.difficulty || 0;
  const diffText = `difficulty ${d > 0 && d < 1
    ? d.toLocaleString(undefined, { maximumSignificantDigits: 3 })
    : d.toLocaleString(undefined, { maximumFractionDigits: 2 })}`;
  text($('netDifficulty'), net.secondsSinceBlock == null
    ? diffText
    : stale
      ? `${diffText} · no block for ${duration(net.secondsSinceBlock)} — rate above is stale`
      : `${diffText} · last block ${duration(net.secondsSinceBlock)} ago`);
  $('netDifficulty').classList.toggle('warn', stale);

  text($('blockHeight'), (net.blocks || 0).toLocaleString());
  text($('halvingNote'), net.blocksUntilHalving !== undefined
    ? `${net.blocksUntilHalving.toLocaleString()} blocks to halving ${(net.halvingEpoch ?? 0) + 1}`
    : '');

  text($('blocksFound'), String(pool.blocksConfirmed ?? 0));
  text($('blocksPending'),
    `${pool.blocksPending ?? 0} maturing · ${pool.blocksOrphaned ?? 0} orphaned`);

  text($('ttb'), pool.expectedBlockSeconds ? duration(pool.expectedBlockSeconds) : '—');

  // ---- reward split ------------------------------------------------------
  const subsidy = net.blockSubsidy || 0;
  const treasury = net.treasurySubsidy || 0;
  const afterTreasury = subsidy - treasury;
  const poolFeePct = (s.config && s.config.poolFeePercent) || 0;
  const poolFee = Math.floor(afterTreasury * poolFeePct / 100);
  const miners = afterTreasury - poolFee;

  if (subsidy > 0) {
    $('segMiner').style.width = `${(miners / subsidy) * 100}%`;
    $('segPool').style.width = `${(poolFee / subsidy) * 100}%`;
    $('segTreasury').style.width = `${(treasury / subsidy) * 100}%`;
  }

  text($('rwMiner'), `${wam(miners)} WAM`);
  text($('rwPool'), `${wam(poolFee)} WAM`);
  text($('rwTreasury'), net.treasuryActive === false
    ? '0.00000000 WAM (ended)'
    : `${wam(treasury)} WAM`);
  text($('rwTotal'), `${wam(subsidy)} WAM`);

  // The treasury fee is time-limited; show miners exactly how much of it is left.
  const sunsetNote = $('treasurySunset');
  if (sunsetNote) {
    if (net.treasuryActive === false) {
      text(sunsetNote,
        `Treasury fee ended at block ${(net.treasuryLastHeight || 0).toLocaleString()}. ` +
        'Miners now receive 100% of the subsidy.');
    } else if (net.blocksUntilTreasuryEnds !== undefined) {
      text(sunsetNote,
        `Treasury fee ends at block ${(net.treasuryLastHeight || 0).toLocaleString()} — ` +
        `${net.blocksUntilTreasuryEnds.toLocaleString()} blocks ` +
        `(~${duration(net.blocksUntilTreasuryEnds * 120)}). After that miners take 100%.`);
    }
  }

  // ---- ports -------------------------------------------------------------
  const portTable = $('portTable');
  portTable.replaceChildren();
  const head = document.createElement('tr');
  for (const h of ['Port', 'Start diff', 'For']) {
    const th = document.createElement('th');
    th.textContent = h;
    head.appendChild(th);
  }
  portTable.appendChild(head);

  const ports = (s.config && s.config.ports) || [];
  for (const p of ports) {
    const tr = document.createElement('tr');
    cell(tr, p.tls ? `${p.port}  🔒` : String(p.port));
    cell(tr, String(p.difficulty ?? '—'), 'num');
    cell(tr, p.description || '');
    portTable.appendChild(tr);
  }

  // Offer the encrypted port in the example command whenever one exists.
  //
  // On plain stratum anyone on the path can substitute the block template,
  // so a miner spends its electricity on a job that pays a stranger and sees
  // nothing wrong. The command shown here is the one most people paste, so
  // it should be the safe one -- an encrypted port nobody is told about
  // protects nobody.
  const host = (s.config && s.config.stratumHost) || window.location.hostname;
  const tlsPort = ports.find((p) => p.tls);
  const chosen = tlsPort || (ports.length ? ports[0] : { port: 3333, tls: false });
  const scheme = chosen.tls ? 'stratum+ssl' : 'stratum+tcp';
  text($('connectCmd'),
    `xmrig -a rx/wam -o ${scheme}://${host}:${chosen.port} \\\n` +
    `      -u YOUR_W_ADDRESS.rig1 -p x --keepalive`);

  // ---- randomx -----------------------------------------------------------
  const rx = s.randomx || {};
  text($('seedHeight'), rx.seedHeight === 0 ? 'bootstrap'
    : (rx.seedHeight ?? '—').toLocaleString ? rx.seedHeight.toLocaleString() : '—');
  text($('seedRotate'), rx.nextRotationInBlocks
    ? `${rx.nextRotationInBlocks} blocks (~${duration(rx.nextRotationInBlocks * 120)})`
    : '—');

  text($('updatedAt'), `updated ${new Date(s.updatedAt || Date.now()).toLocaleTimeString()}`);
}

function renderHealth(h) {
  const pill = $('healthPill');
  pill.classList.remove('ok', 'bad');
  if (h.ok) {
    pill.classList.add('ok');
    text($('healthText'), `healthy · up ${duration(h.uptimeSec)}`);
  } else {
    pill.classList.add('bad');
    text($('healthText'), h.problems.join(' · '));
  }
}

function renderMiners(miners) {
  const tbody = $('minersTable').querySelector('tbody');
  text($('connectedCount'), miners.length ? `(${miners.length})` : '');

  if (!miners.length) return emptyRow(tbody, 6, 'no miners connected');

  tbody.replaceChildren();
  miners.sort((a, b) => b.validShares - a.validShares);

  for (const m of miners) {
    const tr = document.createElement('tr');
    cell(tr, m.worker || '—', 'mono');
    cell(tr, m.userAgent || 'unknown');
    cell(tr, Number(m.difficulty).toLocaleString(), 'num');
    cell(tr, String(m.validShares), 'num');
    cell(tr, String(m.invalidShares), 'num');
    cell(tr, duration(m.connectedFor), 'num');
    tbody.appendChild(tr);
  }
}

function renderBlocks(data) {
  const tbody = $('blocksTable').querySelector('tbody');

  const rows = [
    ...(data.pending || []).map((b) => ({ ...b, status: 'pending' })),
    ...(data.confirmed || []).map((b) => ({ ...b, status: 'confirmed' })),
    ...(data.orphaned || []).map((b) => ({ ...b, status: 'orphaned' }))
  ].sort((a, b) => b.height - a.height).slice(0, 40);

  if (!rows.length) return emptyRow(tbody, 7, 'no blocks yet');

  tbody.replaceChildren();
  for (const b of rows) {
    const tr = document.createElement('tr');
    cell(tr, (b.height ?? 0).toLocaleString());

    const td = document.createElement('td');
    const badge = document.createElement('span');
    badge.className = `badge ${b.status}`;
    badge.textContent = b.status === 'pending'
      ? `${b.confirmations ?? 0}/100` : b.status;
    td.appendChild(badge);
    tr.appendChild(td);

    const finder = document.createElement('td');
    const span = document.createElement('span');
    span.className = 'mono trunc';
    span.textContent = b.finder || '—';
    span.title = b.finder || '';
    finder.appendChild(span);
    tr.appendChild(finder);

    cell(tr, ago(b.time));
    cell(tr, wam(b.minerPot, 4), 'num');
    cell(tr, wam(b.devFeeAmount, 4), 'num');
    cell(tr, String(b.workers ?? '—'), 'num');
    tbody.appendChild(tr);
  }
}

function renderPayments(payments) {
  const tbody = $('paymentsTable').querySelector('tbody');
  if (!payments || !payments.length) return emptyRow(tbody, 4, 'no payouts yet');

  tbody.replaceChildren();
  for (const p of payments) {
    const tr = document.createElement('tr');
    cell(tr, ago(p.time));

    const td = document.createElement('td');
    const span = document.createElement('span');
    span.className = 'mono trunc';
    span.textContent = p.txid || '—';
    span.title = p.txid || '';
    td.appendChild(span);
    tr.appendChild(td);

    cell(tr, String(p.recipients ?? 0), 'num');
    cell(tr, `${wam(p.total, 4)} WAM`, 'num');
    tbody.appendChild(tr);
  }
}

// ------------------------------------------------------------------- miner

$('lookupForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const address = $('addressInput').value.trim();
  const out = $('minerResult');
  out.classList.remove('hidden');
  out.replaceChildren();

  if (!address) return;

  const p = document.createElement('p');
  p.textContent = 'looking up…';
  out.appendChild(p);

  try {
    const m = await getJSON(`/api/miner?address=${encodeURIComponent(address)}`);

    out.replaceChildren();
    const table = document.createElement('table');
    table.className = 'kv';

    const rows = [
      ['Address', m.address],
      ['Hashrate', hashrate(m.hashrate)],
      ['Unpaid balance', `${wam(m.balance)} WAM`],
      ['Paid all time', `${wam(m.totalPaid)} WAM`],
      ['Active workers', String(Object.keys(m.workers || {}).length)]
    ];

    for (const [k, v] of rows) {
      const tr = document.createElement('tr');
      cell(tr, k);
      cell(tr, v, 'num');
      table.appendChild(tr);
    }
    out.appendChild(table);

    const workers = Object.entries(m.workers || {});
    if (workers.length) {
      const wt = document.createElement('table');
      wt.className = 'kv';
      const head = document.createElement('tr');
      for (const h of ['Worker', 'Hashrate']) {
        const th = document.createElement('th');
        th.textContent = h;
        head.appendChild(th);
      }
      wt.appendChild(head);
      for (const [name, st] of workers) {
        const tr = document.createElement('tr');
        cell(tr, name, 'mono');
        cell(tr, hashrate(st.hashrate), 'num');
        wt.appendChild(tr);
      }
      out.appendChild(wt);
    }
  } catch (err) {
    out.replaceChildren();
    const e2 = document.createElement('p');
    e2.className = 'err';
    e2.textContent = `lookup failed: ${err.message}`;
    out.appendChild(e2);
  }
});

// -------------------------------------------------------------------- loop

async function refresh() {
  try {
    const [stats, health, miners, blocks, payments] = await Promise.all([
      getJSON('/api/stats'),
      getJSON('/api/health'),
      getJSON('/api/miners'),
      getJSON('/api/blocks'),
      getJSON('/api/payments')
    ]);

    renderStats(stats);
    renderHealth(health);
    renderMiners(miners.miners || []);
    renderBlocks(blocks);
    renderPayments(payments.payments || []);
  } catch (err) {
    const pill = $('healthPill');
    pill.classList.remove('ok');
    pill.classList.add('bad');
    text($('healthText'), `API unreachable: ${err.message}`);
  }
}

refresh();
setInterval(refresh, REFRESH_MS);

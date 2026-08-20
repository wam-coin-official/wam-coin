# Komodo Wallet — what a submission needs

A pull request to [`KomodoPlatform/coins`](https://github.com/KomodoPlatform/coins),
not a web form. Four things go in, and one of them does not exist yet.

| | Where | State |
|---|---|---|
| Coin entry | appended to `coins` | [`coin-entry.json`](coin-entry.json) |
| Icon, 200×200 PNG | `icons/wam.png` | `brand/png/wam-platform-200.png` |
| Explorer | `explorers/WAM` | `https://explorer.wamcoin.org` |
| Electrum servers | `electrums/WAM` | [`electrums-WAM.json`](electrums-WAM.json) — see below |

They also ask for contact details for service alerts, since a listed coin whose
infrastructure goes quiet is their support problem as much as ours.

---

## Every field, and where it comes from

Each value below is duplicated from the consensus source. If they disagree, the
source wins and this file is wrong.

| Field | Value | Source |
|---|---|---|
| `rpcport` | 9554 | `WAM_MAINNET_RPC_PORT` — peer port **minus** one |
| `pubtype` | 73 | `base58Prefixes[PUBKEY_ADDRESS]`, addresses start `W` |
| `p2shtype` | 135 | `base58Prefixes[SCRIPT_ADDRESS]`, start `w` |
| `wiftype` | 190 | `base58Prefixes[SECRET_KEY]`, keys start `V` |
| `bech32_hrp` | `wam` | `bech32_hrp` |
| `segwit` | true | active from height 1 |
| `avg_blocktime` | 120 | `WAM_POW_TARGET_SPACING` |
| `sign_message_prefix` | `WAM Coin Signed Message:\n` | `MESSAGE_MAGIC`, changed by `WAM-021` |

`required_confirmations` is 6, which is twelve minutes at a two-minute target.
Not inherited from Bitcoin's habits: it is the number that gives a comparable
reorg cost on this chain's timing.

---

## The derivation path, and the one field still absent

**`derivation_path` is `m/44'/5718349'`.** It was blank until 2026-08-20 for a
good reason and is filled now for a better one: `wamd` derives there. A wallet
reports `44h/5718349h`, `49h/5718349h`, `84h/5718349h` and `86h/5718349h`, so
the field describes the software Komodo would be talking to rather than
requesting something of it.

`5718349` is `0x57414D`, which is `WAM` in ASCII — the convention Wanchain used
one number above at `0x57414E`. It is declared once, in
`src/wam/wam-params.h`, and `scripts/audit_repo.sh` rejects any file here that
disagrees with it.

**Registration is open and not yet granted.** Say so in the pull request rather
than leaving them to find out: `integration/slips/` holds the submission. If
SatoshiLabs assign a different number it changes in one place and every wallet
made in the meantime is discarded, which costs nothing before mainnet and
everything after.

**`trezor_coin` stays absent.** Hardware wallet support needs the registration
finished, not merely requested, and there is nothing truthful to write until
then.

---

## Electrum servers

Komodo Wallet requires ElectrumX servers with valid SSL for a UTXO coin. Their
repository has an `electrums/` directory and a UTXO coin without an entry there
is not usable by the wallet — it has no way to read balances.

One now runs. `electrum.wamcoin.org` serves the Electrum protocol on 50001 and
50002 behind a Let's Encrypt certificate, and was verified from outside the
machine rather than on it: the TLS handshake completes for a client with no
override, `server.version` answers, `blockchain.headers.subscribe` returns the
height the node reports with an 80-byte header, and `server.features` returns
this chain's genesis hash. `integration/electrumx/install.sh` reproduces it.

Three things are still not true, and the entry cannot be sent until they are.

**It serves testnet.** Komodo lists mainnet, and mainnet does not exist until
launch. The same installer run with `--network mainnet` produces the mainnet
server; nothing else about it changes.

**`electrum2.wamcoin.org` does not exist.** The file lists two hosts because
one Electrum server is a single point of failure — if it stops, every light
wallet holding WAM goes blind at once, and that becomes Komodo's support
problem, which is exactly what they are protecting against. The second belongs
on a different provider from the first: the two current nodes are at Contabo
and Hetzner, and the measured difference between those two networks is already
recorded in `scripts/check_reachable.sh`.

**Port 50004 serves nothing.** `ws_url` is how Komodo's *web* wallet reaches an
Electrum server; the desktop and mobile builds use 50002 directly. Serving it
means adding `wss://:50004` to `SERVICES` in the ElectrumX environment file,
with the same certificate. The field is in the JSON because leaving it out
quietly drops web users, which is a worse way to find out.

The two venues ranked most likely to fit — BasicSwap and Block DX — run `wamd`
itself and never speak the Electrum protocol, so neither was ever blocked by
any of this.

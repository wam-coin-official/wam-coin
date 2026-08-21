# Komodo Wallet — what a submission needs

A pull request to [`KomodoPlatform/coins`](https://github.com/KomodoPlatform/coins),
not a web form. Four things go in, and all four are ready.

Only one thing still blocks the submission, and it is not one of them: these
files describe mainnet, and mainnet opens on 15 September 2026. Everything
that could be built before that day now is.

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

**Both now run**, on deliberately different providers, and both were verified
from outside the machines rather than on them — `scripts/check_electrum.py`
speaks the protocol, compares the height each one claims against the node over
ssh, and probes every A record behind a name separately:

```
electrum.wamcoin.org    169.58.159.165:50002 SSL   height 537, ElectrumX 2.0.0
                        169.58.159.165:50001 TCP   height 537
electrum2.wamcoin.org     5.223.52.200:50002 SSL   height 537, ElectrumX 2.0.0
                          5.223.52.200:50001 TCP   height 537
```

`electrum` is at Contabo and `electrum2` at Hetzner. Two servers on one
provider are one outage, which is the failure Komodo's support desk absorbs.
50004 carries the Electrum protocol over WebSocket for Komodo's *web* wallet
and is open on both; desktop and mobile use 50002 directly.

Getting there found two faults worth recording, neither of which any check
would have reported:

**The first server was down for 39 hours.** Stopped during the testnet reset on
2026-08-20 and never restarted. `systemctl` showed `inactive` with
`Result=success`, so nothing looked wrong, and `sweep.sh` ran in that window
and reported 14 passed — because no check had ever asked. `check_electrum.py`
exists for that reason and is now in the sweep.

**`electrum.wamcoin.org` resolved to two addresses** and only one had ever run
the service, so half of all connections failed even while the server was up.
Any check that resolved the name once and got lucky would have passed.

**One thing is still not true.** They serve testnet, and Komodo lists mainnet.
The same installer with `--network mainnet` produces the mainnet server and
nothing else about either host changes — so on launch day this is a restart,
not a build under time pressure.

The two venues ranked most likely to fit — BasicSwap and Block DX — run `wamd`
itself and never speak the Electrum protocol, so neither was ever blocked by
any of this.

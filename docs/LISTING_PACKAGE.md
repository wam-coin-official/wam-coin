# WAM Coin — integration and listing package

Everything an exchange, wallet or explorer needs in order to integrate WAM,
on one page. Send this link rather than answering a form field at a time.

**Status:** mainnet launches **2026-09-15 00:00 UTC**. Until that date the
mainnet chain does not exist, and only testnet is live. Nothing below is a
projection — the parameters are final and already committed to source.

---

## 1. Identity

| | |
|---|---|
| Name | WAM Coin |
| Ticker | WAM |
| Consensus | Proof of work, **RandomX** (CPU) |
| Base | Bitcoin Core v28.1 fork |
| Licence | MIT |
| Source | https://github.com/wam-coin-official/wam-coin |
| Website | https://wamcoin.org |
| Explorer | https://explorer.wamcoin.org |
| Contact | wam.coin.official@proton.me |

**Integration cost is low and this is the main thing worth knowing:** WAM is a
Bitcoin Core fork, not a rewrite. The RPC interface, wallet API, address
handling, PSBT support and block structure are Bitcoin's. Any system that
already integrates Bitcoin can integrate WAM with configuration rather than new
code — the differences are the constants in section 3.

---

## 2. Monetary policy

| | |
|---|---|
| Maximum supply | 22,000,000 WAM |
| Block time | 120 seconds |
| Initial subsidy | 50 WAM |
| Halving interval | 200,000 blocks (~13.9 months) |
| Difficulty algorithm | DarkGravityWave v3, retargets every block |
| Decimals | 8 |
| Smallest unit | 1 satoshi-equivalent = 0.00000001 WAM |

**Premine:** 2,000,000 WAM (9.09%) in the genesis block, paid to the founder
address in five outputs. **Every one is time-locked with
OP_CHECKLOCKTIMEVERIFY; none is spendable at launch.** They unlock on
2027-09-15, 2028-09-15, 2029-09-15, 2030-09-15 and 2031-09-15.

**Treasury:** 5% of each block subsidy, heights 1 to 400,000 only, then zero
forever. 750,000 WAM total over roughly 18 months.

Founder + treasury = 2,750,000 = **12.50%** of the cap. Public mining = 87.50%.

Both are enforced by consensus, not by policy. The locks are bare scripts in
the genesis block, so the schedule can be read directly:

```
wam-cli getblock $(wam-cli getblockhash 0) 2
```

---

## 3. Chain parameters

### Mainnet

| | |
|---|---|
| Network magic | `0x57 0x41 0x4d 0x21` ("WAM!") |
| P2P port | 9555 |
| RPC port | 9554 |
| Genesis hash | `d8d3debea987b62a0934c3980d62bffbb6e16aa797d19891d4fcc9b9fb11d7e9` |
| Genesis merkle root | `230fc579dfbad4cec208c43392e3178760fcd74617e4ef22903eae7bf7fcff29` |
| Genesis time | 1789430400 (2026-09-15 00:00 UTC) |
| Genesis nBits | `0x1e0ffff0` |
| Genesis nonce | 1264205 |
| PUBKEY_ADDRESS | 73 — addresses start with `W` |
| SCRIPT_ADDRESS | 135 — addresses start with `w` |
| SECRET_KEY (WIF) | 190 — keys start with `V` |
| bech32 HRP | `wam` |
| BIP32 xpub | `0x0488B21E` |
| BIP32 xprv | `0x0488ADE4` |
| DNS seeds | seed1.wamcoin.org, seed2.wamcoin.org, seed3.wamcoin.org |

### Testnet

| | |
|---|---|
| Network magic | `0x77 0x61 0x6d 0x21` ("wam!") |
| P2P port | 19555 |
| RPC port | 19554 |
| Genesis hash | `ce81c20a59a9586946d46177317658575b9d1c1fc07912b5488ab76202f59bcb` |
| PUBKEY_ADDRESS | 65 — `T` |
| SCRIPT_ADDRESS | 128 — `t` |
| SECRET_KEY (WIF) | 239 — `c` |
| bech32 HRP | `twam` |
| DNS seed | testnet-seed.wamcoin.org |

**Note on RPC ports.** They are the peer port **minus one**, not plus one.
Bitcoin Core reserves peer+1 for its Tor onion listener, so 9556 and 19556 are
taken and must not be used for RPC.

---

## 4. Consensus features

Active from **height 1**. There is no legacy chain to stay compatible with, so
none of Bitcoin's activation scaffolding is carried:

| Feature | Status |
|---|---|
| SegWit | active from height 1 |
| Taproot | active from height 1 |
| CSV (BIP68/112/113) | active from height 1 |
| CLTV (BIP65) | active from height 1 |
| BIP34 / BIP66 | active from height 1 |
| Address types | P2PKH, P2SH, P2WPKH, P2WSH, P2TR |
| PSBT | supported (BIP174) |

**For atomic swap integrators:** CLTV and CSV are active from the first block
and the scripting language is Bitcoin's, so HTLCs work without any adaptation.
This is what makes WAM straightforward for BasicSwap, Block DX, Komodo and
similar venues, and it is why no bridge or wrapped token is involved.

**WAM is a layer 1, not a token.** It cannot be listed on an AMM-style DEX such
as Uniswap without a wrapped representation and a bridge, for the same reason
Monero cannot. Atomic swap and order-book venues need neither.

---

## 5. Consensus rules that differ from Bitcoin

Every difference from Bitcoin Core is a scripted, anchored transformation in
`scripts/patch_upstream.py`. Run it to read all of them with their reasons:

```
python3 scripts/patch_upstream.py --list
```

The two that affect validation:

**WAM-1 — mandatory treasury output.** Every block from height 1 to 400,000
must pay exactly 5% of the subsidy to the treasury address, or it is invalid.
From 400,001 the rule stops applying and miners keep 100%.

**RandomX proof of work.** The 80-byte header is Bitcoin's, with the nonce at
byte 76. The PoW hash is RandomX over that header; the block id remains
double-SHA256 of the header, as in Bitcoin. The RandomX key rotates every 2048
blocks with a 64-block lag on mainnet.

---

## 6. Software

Releases, with SHA256SUMS, are published at:

    https://github.com/wam-coin-official/wam-coin/releases

Built by GitHub Actions from the tagged commit on ubuntu-22.04, so the binaries
run on Ubuntu 22.04 and newer; the workflow is `.github/workflows/release.yml`
and the build is reproducible from source with `./install.sh --build-only`.

| Binary | Purpose |
|---|---|
| `wamd` | full node daemon |
| `wam-cli` | RPC client |
| `wam-tx` | transaction utility |
| `wam-util` | block/header utility |
| `wam-wallet` | offline wallet tool |

Runtime dependencies: libevent and libsqlite3. Nothing else — ZMQ is disabled
deliberately.

### Electrum protocol

An ElectrumX server runs, so a light wallet can read a balance without holding
the chain. Komodo Wallet requires one before it will list a UTXO coin at all;
it is useful whether or not any venue asks.

| | |
|---|---|
| Host | `electrum.wamcoin.org` |
| TCP | 50001 |
| SSL | 50002 (Let's Encrypt, renewing automatically) |
| WebSocket | 50004 |
| Implementation | spesmilo/electrumx, with the WAM coin class in `integration/electrumx/` |

It serves testnet today, because that is the only WAM network that exists. The
same installer produces the mainnet server; `integration/electrumx/install.sh`
is the whole recipe, and `integration/komodo/electrums-WAM.json` is the entry
their repository takes.

The server holds no keys and can spend nothing. It reads the node and answers
questions.

---

## 7. Assets

All transparent PNG, square, the coin masked to its own circle — no background
is baked in, so they sit correctly on a light or a dark interface.

| | Path |
|---|---|
| **Listing logo, 200×200** | `brand/png/wam-platform-200.png` |
| Listing logo, other sizes | `wam-platform-{32,64,128,256,512,2048}.png` |
| Social / announcement image | `brand/png/wam-social-{512,1024,2048}.png` |
| Masters (JPEG, 1080) | `wam-platform-master-1080.jpg`, `wam-social-master-1080.jpg` |
| Whitepaper | `WHITEPAPER.md` |

The listing logo carries the mark alone. The social image is the same coin with
`22,000,000` and the launch date struck into it — correct for an announcement,
wrong for a listing, where it is rendered at 32 pixels and the text becomes
noise.

---

## 8. What we do not claim

WAM has no market value and is not listed on any exchange. Two independent
developers have reviewed the code and their findings were adopted -- see
review/REVIEW_RESPONSE.md -- but no security firm has been engaged to audit
the consensus changes, and peer review is not an audit. The chain has not launched. There is no presale, no
ICO, no private round and no allocation to anyone but the founder reserve and
treasury described above — both disclosed here and enforced by every node.

We would rather you knew all of that before spending time on an integration
than after.

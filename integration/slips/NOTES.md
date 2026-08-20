# SLIP registrations — the number every other listing waits on

Two pull requests to [`satoshilabs/slips`](https://github.com/satoshilabs/slips),
each adding one row to a table. No fee, no form, no account beyond a GitHub
one. They are listed here because three separate integrations are blocked
until the first of them lands, and because both are decisions that cannot be
taken back once anyone holds coins.

---

## 1. SLIP-0044 — the BIP-44 coin type

Level 2 of the derivation path: `m / 44' / coin_type' / account' / ...`

Add to `slip-0044.md`, in the numeric order the table already keeps:

```
| 5655640    | VLX     | Velas                             |
| 5718349    | WAM     | WAM Coin                          |    <- this row
| 5718350    | WAN     | Wanchain                          |
```

### Why that number

`0x57414D` is `WAM` read as ASCII. The registry has no free number below a
thousand — all 1,473 entries were checked on 2026-08-20 — and recent
registrations use exactly this convention: TNZO holds `0x544E5A4F`,
Bitcoin-PoCX holds `0x504F4358`.

The row immediately below is the argument by itself. Wanchain holds
**5718350**, which is `0x57414E`, which is `WAN`. The same scheme, the adjacent
ticker, one number apart. Ours slots into a gap that exists because nobody
called their coin WAM.

### Their condition, and how it is already met

The document's own sentence, at the end of the table:

> Coin types will be added only if there is a wallet implementing BIP-0044 for
> desired coin.

Until 2026-08-20 WAM did not meet it. `walletutil.cpp` still carried Bitcoin's
hardcoded 0, so every WAM wallet derived at `m/84'/0'/0'` — Bitcoin's branch,
the same keys the same seed opens in a Bitcoin wallet. WAM-023 fixed that; a
wallet now reports:

```
44h/5718349h   49h/5718349h   84h/5718349h   86h/5718349h
```

and testnet stays at `1h`, which SLIP-44 reserves for every test chain so test
keys can never be mistaken for real ones.

So the pull request can say, truthfully, that the wallet implementing BIP-44
for this coin exists and already derives at the number being requested.

---

## 2. SLIP-0173 — the bech32 human-readable parts

Add to `slip-0173.md`, between `VIPSTARCOIN` and `Wpc`:

```
| VIPSTARCOIN              | `vips`        | `tvips`  |             |
| WAM Coin                 | `wam`         | `twam`   | `wamrt`     |    <- this row
| Wpc                      | `wpc`         |          |             |
```

All three were checked against the 438 registered prefixes on 2026-08-20 and
none is claimed.

This one has no gatekeeping condition, and it is the cheaper of the two to
neglect and the more annoying to lose. Without it another chain can register
`wam` tomorrow, and from then on two networks answer to the same address
prefix — which wallets resolve by guessing.

---

## What this unblocks

| Waiting on the coin type | Why |
|---|---|
| BasicSwap | their params dict has a `bip44` field and it is left as a comment |
| Komodo Wallet | `derivation_path` is absent from `coin-entry.json` for the same reason |
| Hardware wallets | Trezor and Ledger derive from the registry; no number, no support |

`scripts/audit_repo.sh` refuses any invented value in `integration/`, so none
of those three can quietly acquire a made-up number while the real one is
pending.

## The part that cannot be undone

A coin type is not a label. Change it after people hold coins and the same
seed derives different addresses, so a restored wallet looks empty and its
owner has done nothing wrong. It belongs to the same list as the treasury
address: **settled before the first mainnet block, not after.**

If SatoshiLabs assign something other than 5718349, the constant in
`src/wam/wam-params.h` changes and every wallet made in the meantime is
discarded. Today that costs nothing — mainnet has no blocks and every testnet
wallet is disposable. In three weeks it costs everything.

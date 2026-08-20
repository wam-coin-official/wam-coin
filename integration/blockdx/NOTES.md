# Block DX — what a submission needs

Block DX replied to the enquiry sent 2026-08-18 and pointed at a GitHub
repository. The one that matters is not `blocknetdx/block-dx`, which is the
client, but
[`blocknetdx/blockchain-configuration-files`](https://github.com/blocknetdx/blockchain-configuration-files),
which is where the 142 coins it can trade are described.

An earlier version of this directory held a single `xbridge.conf` written from
a general idea of what XBridge wants. That was wrong in form: their repository
takes three separate things, and a pull request shaped like the guess would not
have applied.

## The three files

| From here | To there |
|---|---|
| [`xbridge-confs/wamcoin--v0.1.3.conf`](xbridge-confs/wamcoin--v0.1.3.conf) | `xbridge-confs/wamcoin--v0.1.3.conf` |
| [`wallet-confs/wamcoin--v0.1.3.conf`](wallet-confs/wamcoin--v0.1.3.conf) | `wallet-confs/wamcoin--v0.1.3.conf` |
| [`manifest-entry.json`](manifest-entry.json) | one object appended to `manifest-latest.json` |

## Every value, and where it comes from

Read off `bitcoin--v0.17.0.conf` in their repository, because WAM is a Bitcoin
Core fork and that entry is the closest thing they already ship.

| Field | Value | Source |
|---|---|---|
| `Port` | 9554 | RPC port, not p2p — their `Port` is what XBridge calls |
| `AddressPrefix` | 73 | `base58Prefixes[PUBKEY_ADDRESS]` |
| `ScriptPrefix` | 135 | `base58Prefixes[SCRIPT_ADDRESS]` |
| `SecretPrefix` | 190 | `base58Prefixes[SECRET_KEY]` |
| `BlockTime` | 120 | `WAM_POW_TARGET_SPACING` |
| `COIN` | 100000000 | eight decimals, as Bitcoin |
| `dir_name_linux` | `wam` | the node's own default data directory is `~/.wam` |
| `conf_name` | `wam.conf` | measured by running `wamd`, not assumed |

**`GetNewKeySupported=false` and `ImportWithNoScanSupported=false`** follow
Bitcoin v0.17 rather than Litecoin v0.15. Those two flags describe a wallet
that will hand out a raw private key and import one without a rescan, which
descriptor wallets in modern Core do not do. WAM is a v28.1 fork, so claiming
otherwise would fail at the first swap rather than at submission.

**`MinTxFee=10000` and `FeePerByte=10`** are Litecoin's numbers, not Bitcoin's
12000/60, because those reflect a congested fee market WAM does not have. Ten
satoshis per byte is ten times the relay minimum a WAM node enforces, which
leaves room without inventing a fee market.

## The version in the filename

Their names carry the wallet version a config was verified against —
`litecoin--v0.15.1.conf`. Ours says `v0.1.3` for the same reason, and a new
file goes beside it when a release changes anything XBridge reads. That has not
happened yet and the file is written the day it does.

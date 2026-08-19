# Integration files, prepared in advance

Everything a venue needs from us, written out before it is asked for, so that
answering a listing enquiry is copying a file rather than starting work.

Each subdirectory holds what that venue actually consumes. Three of the six
take a pull request with a config file rather than a web form.

| Venue | What it consumes | Ready |
|---|---|---|
| [Komodo Wallet](komodo/) | PR to `KomodoPlatform/coins`: coin entry, electrum servers, explorer, icon | coin entry ✅ · **electrum servers ❌** |
| [BasicSwap DEX](basicswap/) | coin definition; it runs `wamd` itself | ✅ |
| [Block DX](blockdx/) | XBridge config entry; it runs `wamd` itself | ✅ |
| Bisq | PR plus a maintainer and a BSQ listing fee | waiting on their reply |
| Maya Protocol | chain integration by governance, not a listing | unlikely — not pursued |
| Haveno | Monero-centric; WAM is out of scope there | not pursued |

**Nothing here has been submitted.** Enquiries asking each venue what it
requires were sent 2026-08-18; none has replied and none has agreed to
anything. These files exist so that when a reply arrives, the answer is already
written.

---

## The one thing missing

Komodo Wallet requires **ElectrumX servers with valid SSL** for a UTXO coin —
it is a directory in their repository, not an optional field. WAM does not have
one yet.

That also blocks nothing else: BasicSwap and Block DX run the daemon directly
and never speak the Electrum protocol.

An Electrum server would additionally let light wallets read balances without
downloading the chain, which is worth having on its own.

---

## Two gaps that need someone else's calendar, not ours

**SLIP-44 coin type.** WAM has none. It is the `coin_type` in a BIP44
derivation path (`m/44'/<type>'`), and no hardware wallet will ever support a
coin without one. Registration is a pull request to `satoshilabs/slips`, and
their merge queue is measured in weeks. `komodo/coin-entry.json` therefore has
no `derivation_path` field, and cannot have one until a number is assigned.

**Message signing prefix.** Fixed here rather than left: WAM used Bitcoin's
`"Bitcoin Signed Message:\n"`, which meant a signature proving control of a WAM
address doubled as proof of control of the corresponding Bitcoin address. It is
now `"WAM Coin Signed Message:\n"` — see `WAM-021` in
`scripts/patch_upstream.py`. Changed before launch because afterwards it would
invalidate every signature already produced.

---

## Keeping these honest

The parameters here are duplicated from `src/wam/wam-params.h` and
`src/wam/chainparams.cpp`. `scripts/audit_repo.sh` checks that the values in
this directory still match the source, for the same reason the vesting schedule
is checked in three files: a listing config that disagrees with the chain is an
integration that fails on the first connection, and the venue does not come
back to ask why.

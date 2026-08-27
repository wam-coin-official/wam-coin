Add WAM Coin (WAM)

WAM Coin is a Bitcoin Core v28.1 fork using RandomX proof of work. The RPC
surface, transaction format, script language, SegWit and PSBT are Bitcoin's, so
WAMInterface declares its coin type and inherits everything else from
BTCInterface. LTCInterface is large because of MimbleWimble and DASHInterface
because of Dash's address handling; WAM has neither, and overrides that repeat
the parent would be code to maintain for no behaviour.

RandomX does not enter a swap. It changes how a header is proved, not how a
transaction is built or spent, and no part of the protocol reads proof of work.

  basicswap/interface/wam/__init__.py
  basicswap/interface/wam/chainparams.py
  basicswap/interface/wam/wam.py
  basicswap/chainparams.py              (import + Coins member)

One thing to flag rather than bury: bip44 is 5718349, which is 0x57414D --
"WAM" in ASCII, the convention Wanchain used one number above at 0x57414E. It
is not invented for this file. wamd already derives there; listdescriptors
returns 44h/5718349h, 49h/5718349h, 84h/5718349h and 86h/5718349h. But the
SLIP-44 registration is granted: satoshilabs/slips PR #2051, merged
2026-08-26. Coin type 5718349 and the bech32 prefixes wam / twam / wamrt
are reserved to this chain in SLIP-0044 and SLIP-0173.

The number is decided in one place, `WAM_BIP44_COIN_TYPE` in
`src/wam/wam-params.h`, and `scripts/audit_repo.sh` rejects any file in this
submission that disagrees with it.

Source:   https://github.com/wam-coin-official/wam-coin
Explorer: https://explorer.wamcoin.org

Mainnet is scheduled for 2026-09-15.

Add WAM Coin (WAM)

WAM Coin is a Bitcoin Core v28.1 fork using RandomX proof of work. Its RPC
surface, transaction format, script language and SegWit are Bitcoin's, so
XBridge needs only the usual three files.

  xbridge-confs/wamcoin--v0.1.3.conf
  wallet-confs/wamcoin--v0.1.3.conf
  manifest-latest.json                 (one entry)

Values were taken from bitcoin--v0.17.0.conf rather than from a general idea of
what XBridge wants, and two of them are judgements worth stating:

GetNewKeySupported and ImportWithNoScanSupported are false, following Bitcoin
v0.17 rather than Litecoin v0.15. Those flags describe a wallet that hands out
a raw private key and imports one without a rescan, which descriptor wallets in
Core 28 do not do. Claiming otherwise would fail at the first swap rather than
at review.

MinTxFee 10000 and FeePerByte 10 follow Litecoin rather than Bitcoin's
12000/60, because those reflect a fee market this chain does not have. Ten
satoshis a byte is ten times what a WAM node requires to relay.

dir_name_linux and conf_name were read off a running node (~/.wam, wam.conf)
rather than assumed from the coin's name.

Source:   https://github.com/wam-coin-official/wam-coin
Explorer: https://explorer.wamcoin.org
Releases: https://github.com/wam-coin-official/wam-coin/releases

Mainnet is scheduled for 2026-09-15, so the chain these configs describe has no
blocks yet. Happy to hold this open until it does.

Register WAM Coin: SLIP-0044 coin type 5718349 and SLIP-0173 hrp wam

WAM Coin is a Bitcoin Core v28.1 fork using RandomX proof of work.

SLIP-0044
---------
5718349 is 0x57414D, which is "WAM" in ASCII. The registry has no free number
below a thousand, and this follows what recent entries do -- the row
immediately below is Wanchain at 5718350, which is 0x57414E, "WAN". The same
scheme with the adjacent ticker.

The document's condition is that a wallet implementing BIP-0044 for the coin
must already exist. It does, and it derives at the number requested here:

  $ wam-cli -rpcwallet=w listdescriptors | grep -o "8[46]h/[0-9]*h"
  84h/5718349h
  86h/5718349h

Testnet is left at 1, as SLIP-0044 reserves it.

SLIP-0173
---------
wam, twam and wamrt for mainnet, testnet and regtest. None appears among the
registered prefixes.

Source:   https://github.com/wam-coin-official/wam-coin
Explorer: https://explorer.wamcoin.org

Mainnet launches 2026-09-15. Both values are being registered before the first
block rather than after, so that no wallet is ever restored onto a branch that
has since moved.

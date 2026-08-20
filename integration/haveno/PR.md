Add WAM Coin (WAM)

WAM Coin is a Bitcoin Core v28.1 fork using RandomX proof of work. Address
handling, the transaction format, the script language and SegWit are Bitcoin's,
so this needs only the three constants BitcoinAddressValidator reads:

  addressHeader    73    'W'
  p2shHeader      135    'w'
  segwitAddressHrp  wam

Every address in the test came from the coin's own node rather than being
written by hand: the valid ones from getnewaddress on mainnet, and each invalid
one was handed to validateaddress and refused. They cover a Bitcoin address
whose version byte differs, a bc1 address whose hrp differs, a testnet twam1
address that must not validate as mainnet, and a valid address with its last
character changed so the checksum has to catch it.

Source:   https://github.com/wam-coin-official/wam-coin
Explorer: https://explorer.wamcoin.org

The chain has not launched yet; mainnet is scheduled for 2026-09-15. I am aware
the listed set is deliberately small and every coin in it is far larger than
this one, so a no is a perfectly reasonable answer and no explanation is owed.
The submission is here in case the answer is otherwise, and it costs you only
the time to read three constants.

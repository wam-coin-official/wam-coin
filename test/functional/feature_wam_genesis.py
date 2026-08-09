#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""The genesis premine: five tranches, four of them time-locked.

Bitcoin's genesis coinbase is deliberately unspendable -- it was never added to
the UTXO set. WAM patches that, because the genesis block *is* the premine. If
that patch ever silently stopped working, the chain would start with two
million WAM that exist in the block and nowhere else: `getsupplyinfo` would
report them, an explorer would show them, and they could never be spent. The
failure would look exactly like success until someone tried.

So this checks the outputs are real UTXOs, not just bytes in a block.

It also checks the four locked tranches carry CHECKLOCKTIMEVERIFY with the
dates the whitepaper promises. Those dates are the whole basis of the founder
disclosure; they are readable from block 0 by anyone, and this makes sure they
stay that way.
"""

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_greater_than

COIN = 100_000_000

# From src/wam/wam-params.h. Kept as literals on purpose: a test that imports
# the value it is testing proves nothing.
PREMINE_TOTAL = 2_000_000 * COIN
TRANCHE_AMOUNT = 400_000 * COIN
TRANCHE_COUNT = 5
UNLOCK_TIMES = [
    0,           # tranche 1 -- spendable from genesis
    1820966400,  # 2027-09-15
    1852588800,  # 2028-09-15
    1884124800,  # 2029-09-15
    1915660800,  # 2030-09-15
]

OP_CHECKLOCKTIMEVERIFY = 0xb1
OP_DROP = 0x75


class WamGenesisTest(BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True

    def run_test(self):
        node = self.nodes[0]

        genesis_hash = node.getblockhash(0)
        genesis = node.getblock(genesis_hash, 2)
        coinbase = genesis['tx'][0]

        self.log.info('the genesis coinbase carries five outputs')
        assert_equal(len(coinbase['vout']), TRANCHE_COUNT)

        self.log.info('each tranche is 400,000 WAM and they total two million')
        total = 0
        for i, out in enumerate(coinbase['vout']):
            value = int(round(out['value'] * COIN))
            assert_equal(value, TRANCHE_AMOUNT)
            total += value
        assert_equal(total, PREMINE_TOTAL)

        self.log.info('tranche 1 is spendable, with no lock on it')
        first = bytes.fromhex(coinbase['vout'][0]['scriptPubKey']['hex'])
        assert OP_CHECKLOCKTIMEVERIFY not in first, \
            'the first tranche must not be time-locked; it funds the launch'

        self.log.info('tranches 2 to 5 are locked to the promised dates')
        for i in range(1, TRANCHE_COUNT):
            script = bytes.fromhex(coinbase['vout'][i]['scriptPubKey']['hex'])

            # <locktime> OP_CHECKLOCKTIMEVERIFY OP_DROP <p2pkh...>
            push_len = script[0]
            assert 1 <= push_len <= 5, \
                f'tranche {i + 1} does not begin with a locktime push'
            locktime = int.from_bytes(script[1:1 + push_len], 'little')
            assert_equal(locktime, UNLOCK_TIMES[i])
            assert_equal(script[1 + push_len], OP_CHECKLOCKTIMEVERIFY)
            assert_equal(script[2 + push_len], OP_DROP)

            # A timestamp, not a height. CLTV compares against one or the other
            # depending on which side of 500,000,000 the value falls, and a
            # lock that was meant for 2030 but reads as height 1,820,966,400
            # would never open at all.
            assert_greater_than(locktime, 500_000_000)
            self.log.info(f'  tranche {i + 1}: locked until {locktime}')

        self.log.info('every tranche is a real, spendable-in-principle UTXO')
        for i in range(TRANCHE_COUNT):
            utxo = node.gettxout(coinbase['txid'], i)
            assert utxo is not None, (
                f'tranche {i + 1} is in the genesis block but not in the UTXO set. '
                'The premine would be unspendable forever.')
            assert_equal(int(round(utxo['value'] * COIN)), TRANCHE_AMOUNT)

        self.log.info('getsupplyinfo agrees with the block')
        info = node.getsupplyinfo()
        assert_equal(info['height'], 0)
        assert_equal(int(round(info['premine'] * COIN)), PREMINE_TOTAL)
        assert_equal(int(round(info['circulating'] * COIN)), PREMINE_TOTAL)

        self.log.info('the emission schedule the node reports is its own, not a guess')
        assert_greater_than(info['halving_interval'], 0)
        assert_equal(info['next_halving_height'], info['halving_interval'])
        self.log.info(f"  halving interval {info['halving_interval']}, "
                      f"next at {info['next_halving_height']}")

        self.log.info('mining does not disturb the premine')
        self.generatetodescriptor(node, 5, 'raw(51)#8lvh9jxk')
        after = node.getsupplyinfo()
        assert_equal(int(round(after['premine'] * COIN)), PREMINE_TOTAL)
        assert_greater_than(after['circulating'], info['circulating'])

        for i in range(TRANCHE_COUNT):
            assert node.gettxout(coinbase['txid'], i) is not None, \
                f'tranche {i + 1} vanished from the UTXO set after mining'


if __name__ == '__main__':
    WamGenesisTest(__file__).main()

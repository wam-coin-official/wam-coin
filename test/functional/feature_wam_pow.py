#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""Proof of work is RandomX, and it is actually reached.

WAM once shipped a node that computed RandomX correctly, documented RandomX
everywhere, and then compared the block header's SHA256d against the target --
because the check lived in CheckBlockHeader, which the RandomX patch had not
moved. Every unit test passed. The chain would have accepted blocks that cost
nothing to produce.

A unit test cannot catch that: the bug was not in the hash function, it was in
which hash the validator looked at. Only a real node validating a real block
can tell the difference, and this is how it is told.

THE METHOD
----------
Python cannot compute RandomX, so the test cannot predict which nonces are
valid. It does not need to. On regtest the target is ~2^255, so about half of
all nonces satisfy RandomX and about half satisfy SHA256d -- but they are
different halves.

So: build a block that is invalid for a *contextual* reason (no treasury
output), which is checked after the proof of work. Then for each candidate
nonce the node answers one of two ways:

    high-hash               the proof of work failed
    bad-cb-devfee-amount    the proof of work passed, and validation moved on

Feed it only nonces whose SHA256d already clears the target. If the node were
still checking SHA256d, every one of them would come back
'bad-cb-devfee-amount'. Seeing even one 'high-hash' proves it is not. Over
thirty such nonces the odds of a false pass are about one in a billion.

The block never becomes valid, so the chain never advances and the loop can run
as long as it likes.
"""

import hashlib

from test_framework.blocktools import (
    add_witness_commitment,
    create_block,
    create_coinbase,
)
from test_framework.messages import CTxOut
from test_framework.script import CScript, OP_TRUE
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_greater_than

# SHA256("WAM/RandomX/epoch-0/2026"), the bootstrap key. Written out rather
# than computed so that a change to the string is a test failure, not a silent
# agreement between two copies of the same mistake.
BOOTSTRAP_SEED_DISPLAY = \
    '2b579531d5dc32c712fb26dd061b60c8bb1e0c135c1450bde12fa5c318b6151c'

CANDIDATES = 30


def compact_to_target(bits):
    exponent = bits >> 24
    mantissa = bits & 0x007fffff
    if exponent <= 3:
        return mantissa >> (8 * (3 - exponent))
    return mantissa << (8 * (exponent - 3))


class WamPowTest(BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True

    def run_test(self):
        node = self.nodes[0]
        tmpl = node.getblocktemplate({'rules': ['segwit']})

        self.log.info('the template names the RandomX key for this height')
        assert 'randomx_seedhash' in tmpl, \
            'no randomx_seedhash: a miner would have to guess the key'
        assert 'randomx_seedheight' in tmpl
        assert_equal(len(tmpl['randomx_seedhash']), 64)

        self.log.info('early blocks use the bootstrap key')
        assert_equal(tmpl['randomx_seedheight'], 0)
        assert_equal(tmpl['randomx_seedhash'], BOOTSTRAP_SEED_DISPLAY)

        # The displayed value is a uint256, printed big-endian. RandomX is keyed
        # with the internal bytes, so the key really is the reverse of it -- and
        # that reverse has to be the plain SHA256 digest of the bootstrap string.
        digest = hashlib.sha256(b'WAM/RandomX/epoch-0/2026').digest()
        assert_equal(bytes.fromhex(tmpl['randomx_seedhash'])[::-1].hex(), digest.hex())
        self.log.info('  the key is SHA256("WAM/RandomX/epoch-0/2026"), byte-reversed')

        # ---- build a block that can never be accepted --------------------
        total = tmpl['coinbasevalue']
        coinbase = create_coinbase(tmpl['height'])
        coinbase.vout = [CTxOut(total, CScript([OP_TRUE]))]   # no treasury output
        coinbase.rehash()

        block = create_block(tmpl=tmpl, coinbase=coinbase)
        add_witness_commitment(block)

        target = compact_to_target(int(tmpl['bits'], 16))
        self.log.info(f'regtest target is 2^{target.bit_length() - 1}, '
                      'so roughly half of all nonces clear it')

        self.log.info(f'offering {CANDIDATES} nonces whose SHA256d already passes')
        verdicts = {'high-hash': 0, 'bad-cb-devfee-amount': 0}
        other = []
        tried = 0
        nonce = 0

        while verdicts['high-hash'] + verdicts['bad-cb-devfee-amount'] < CANDIDATES:
            nonce += 1
            if nonce > 100000:
                raise AssertionError('ran out of nonces looking for SHA256d hits')

            block.nNonce = nonce
            block.rehash()
            if block.sha256 > target:
                continue          # SHA256d would have rejected this one anyway

            tried += 1
            result = node.submitblock(block.serialize().hex())
            if result in verdicts:
                verdicts[result] += 1
            else:
                other.append(result)

        self.log.info(f'  {verdicts["high-hash"]} rejected for proof of work, '
                      f'{verdicts["bad-cb-devfee-amount"]} got past it')
        assert_equal(other, [])

        self.log.info('at least one SHA256d-valid block failed the proof of work')
        assert_greater_than(verdicts['high-hash'], 0), (
            'Every nonce whose SHA256d cleared the target also cleared the '
            'proof-of-work check. This chain is validating SHA256d, not RandomX, '
            'and its blocks cost nothing to produce.')

        self.log.info('and at least one got past it, so the check is not rejecting everything')
        assert_greater_than(verdicts['bad-cb-devfee-amount'], 0)

        self.log.info('the chain never moved -- none of those blocks was valid')
        assert_equal(node.getblockcount(), 0)

        self.log.info('the key stays put until the epoch boundary')
        self.generatetodescriptor(node, 20, 'raw(51)#8lvh9jxk')
        later = node.getblocktemplate({'rules': ['segwit']})
        assert_equal(later['randomx_seedheight'], 0)
        assert_equal(later['randomx_seedhash'], BOOTSTRAP_SEED_DISPLAY)
        self.log.info('  still the bootstrap key at height '
                      f"{later['height']}, as it should be")


if __name__ == '__main__':
    WamPowTest(__file__).main()

#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""Consensus rule WAM-1 -- the mandatory treasury output.

Every block from height 1 to 400,000 must pay at least 5% of the subsidy to the
treasury script. The unit tests in src/wam/test/ check the predicate in
isolation; this checks that a real node, running real validation, actually
refuses a real block that breaks it.

The distinction matters. A rule that is implemented but not *reached* is not a
rule -- WAM already shipped one of those: proof of work was verified against
SHA256d instead of RandomX for a while, and every unit test still passed.

Blocks are offered through `getblocktemplate mode=proposal`, which runs full
contextual validation and skips only the proof of work. That is what lets the
test build a deliberately invalid block without first spending a million
RandomX hashes on it. One block is also submitted the ordinary way, so the
path that miners actually use is covered too.
"""

from test_framework.blocktools import (
    add_witness_commitment,
    create_block,
    create_coinbase,
)
from test_framework.descriptors import descsum_create
from test_framework.messages import CTxOut
from test_framework.script import CScript, OP_TRUE
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_greater_than

# The framework's self.generate() mines to a hardcoded Bitcoin regtest address
# (version byte 111). WAM regtest uses 65, so the node rejects it as invalid.
# Mining to a bare script sidesteps address encoding altogether.
ANYONE_CAN_SPEND = descsum_create('raw(51)')      # OP_TRUE


class WamDevFeeTest(BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True

    # ------------------------------------------------------------------
    # helpers
    # ------------------------------------------------------------------

    def template(self):
        return self.nodes[0].getblocktemplate({'rules': ['segwit']})

    def build_block(self, tmpl, *, treasury=None, treasury_script=None,
                    omit_treasury=False):
        """Build a block on the current tip.

        treasury        satoshi to pay the treasury; None means "exactly what
                        consensus requires"
        treasury_script override the destination, to test that paying the right
                        amount to the wrong place is not enough
        omit_treasury   leave the output out entirely
        """
        required = tmpl['devfee']['amount']
        script = bytes.fromhex(tmpl['devfee']['script'])
        total = tmpl['coinbasevalue']

        if treasury is None:
            treasury = required
        if treasury_script is not None:
            script = treasury_script

        coinbase = create_coinbase(tmpl['height'])
        coinbase.vout = []
        if not omit_treasury:
            coinbase.vout.append(CTxOut(treasury, CScript(script)))
            miner_value = total - treasury
        else:
            miner_value = total
        coinbase.vout.append(CTxOut(miner_value, CScript([OP_TRUE])))
        coinbase.rehash()

        block = create_block(tmpl=tmpl, coinbase=coinbase)
        add_witness_commitment(block)
        block.rehash()
        return block

    def propose(self, block):
        """Full contextual validation, no proof of work. None means valid."""
        return self.nodes[0].getblocktemplate({
            'mode': 'proposal',
            'data': block.serialize().hex(),
            'rules': ['segwit'],
        })

    def submit_with_pow(self, block, max_attempts=64):
        """Submit for real, grinding the nonce until RandomX is satisfied.

        Python cannot compute RandomX, but on regtest the target is so easy
        that roughly every other nonce clears it. Asking the node is cheaper
        than binding the library: keep bumping the nonce while it says
        'high-hash', and stop at whatever it says next.
        """
        for _ in range(max_attempts):
            result = self.nodes[0].submitblock(block.serialize().hex())
            if result != 'high-hash':
                return result
            block.nNonce += 1
            block.rehash()
        raise AssertionError(
            f'{max_attempts} nonces failed to satisfy even the regtest target; '
            'RandomX validation is probably not doing what this test assumes')

    # ------------------------------------------------------------------

    def run_test(self):
        node = self.nodes[0]

        self.log.info('the treasury rule is live from height 1')
        tmpl = self.template()
        assert_equal(tmpl['height'], 1)
        assert 'devfee' in tmpl, \
            'getblocktemplate has no devfee field; this is not a WAM daemon'
        assert_greater_than(tmpl['devfee']['amount'], 0)

        required = tmpl['devfee']['amount']
        subsidy = tmpl['coinbasevalue']          # no fees in an empty mempool
        assert_equal(required, subsidy * 5 // 100)
        self.log.info(f'  height 1: subsidy {subsidy}, treasury must be {required}')

        self.log.info('a block that pays exactly the required amount is valid')
        assert_equal(self.propose(self.build_block(tmpl)), None)

        self.log.info('a block with no treasury output is rejected')
        assert_equal(
            self.propose(self.build_block(tmpl, omit_treasury=True)),
            'bad-cb-devfee-amount')

        self.log.info('one satoshi short is still rejected')
        assert_equal(
            self.propose(self.build_block(tmpl, treasury=required - 1)),
            'bad-cb-devfee-amount')

        self.log.info('paying the right amount to the wrong script is rejected')
        assert_equal(
            self.propose(self.build_block(
                tmpl, treasury_script=CScript([OP_TRUE]))),
            'bad-cb-devfee-amount')

        self.log.info('overpaying is allowed -- the rule is a floor, not a ceiling')
        assert_equal(
            self.propose(self.build_block(tmpl, treasury=required * 2)),
            None)

        self.log.info("the node's own template already satisfies the rule")
        assert_equal(self.propose(self.build_block(tmpl)), None)

        self.log.info('a valid block really is accepted by submitblock')
        block = self.build_block(tmpl)
        assert_equal(self.submit_with_pow(block), None)
        assert_equal(node.getblockcount(), 1)
        assert_equal(node.getbestblockhash(), block.hash)

        self.log.info('the accepted block paid the treasury on chain')
        onchain = node.getblock(block.hash, 2)['tx'][0]
        paid = sum(int(round(o['value'] * 10**8)) for o in onchain['vout']
                   if o['scriptPubKey']['hex'] == self.template_script)
        assert_equal(paid, required)

        self.log.info('the rule keeps applying as the chain grows')
        self.generatetodescriptor(node, 20, ANYONE_CAN_SPEND)
        assert_equal(node.getblockcount(), 21)

        tmpl = self.template()
        block = self.build_block(tmpl, treasury=0)
        assert_equal(self.propose(block), 'bad-cb-devfee-amount')
        assert_equal(self.propose(self.build_block(tmpl)), None)

    # the treasury script does not change, so capture it once
    @property
    def template_script(self):
        if not hasattr(self, '_treasury_script'):
            self._treasury_script = self.template()['devfee']['script']
        return self._treasury_script


if __name__ == '__main__':
    WamDevFeeTest(__file__).main()

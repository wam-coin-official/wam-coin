#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""The RandomX key rotates on schedule, and the schedule comes from consensus.

Every 2048 blocks -- 64 on regtest -- the whole network changes the key it
hashes with. It is the most disruptive scheduled event this chain has: every
miner rebuilds a 2 GiB dataset at the same height, and a node that disagrees
by one block about when that happens rejects every block the others produce.

Two things had already gone wrong here, which is why this test exists:

  * `GetRandomXSeedHeight` read the compile-time mainnet constants instead of
    `Consensus::Params`. Mainnet was correct by coincidence -- its parameters
    *are* those constants -- while the test networks silently used 2048/64 and
    `getrandomxinfo` reported something else. Reaching a rotation on regtest
    cost 2,112 blocks instead of the 68 the parameters promised.

  * The pool computed the same schedule from its own copy of the constants and
    announced the next rotation 1,840 blocks late on testnet.

Both were reporting bugs rather than validation bugs, and both survived
because nothing ever compared the reported schedule against the enforced one.
That is exactly what this does.
"""

import hashlib

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import (
    assert_equal,
    assert_greater_than,
    assert_greater_than_or_equal,
)

ANYONE_CAN_SPEND = 'raw(51)#8lvh9jxk'

# SHA256("WAM/RandomX/epoch-0/2026"), displayed big-endian by the RPC.
BOOTSTRAP_SEED_DISPLAY = \
    '2b579531d5dc32c712fb26dd061b60c8bb1e0c135c1450bde12fa5c318b6151c'


class WamRandomXEpochTest(BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True

    def seed_info(self):
        return self.nodes[0].getrandomxinfo()

    def run_test(self):
        node = self.nodes[0]

        self.log.info('the node reports the epoch it actually enforces')
        info = self.seed_info()
        epoch = info['epoch_blocks']
        lag = info['epoch_lag']

        # regtest is configured short on purpose. If this ever reads 2048 the
        # constants have leaked back in and a rotation is out of reach again.
        assert_greater_than(epoch, 0)
        assert_greater_than(epoch, lag)
        assert epoch <= 1024, (
            f'regtest reports a {epoch}-block epoch. chainparams sets a short one '
            'so that a rotation is reachable; reading the mainnet constant here '
            'is the bug this test was written for.')
        self.log.info(f'  epoch {epoch} blocks, lag {lag}')

        # The first height whose key is a block hash rather than the bootstrap
        # string. Derived from what the node reports, never from a constant.
        first_rotation = epoch + lag
        seed_source = epoch

        self.log.info('genesis and the whole first epoch use the bootstrap key')
        assert_equal(info['height'], 0)
        assert_equal(info['seed_height'], 0)
        assert_equal(info['bootstrap'], True)
        assert_equal(info['seed_hash'], BOOTSTRAP_SEED_DISPLAY)

        digest = hashlib.sha256(b'WAM/RandomX/epoch-0/2026').digest()
        assert_equal(bytes.fromhex(info['seed_hash'])[::-1].hex(), digest.hex())
        self.log.info('  the key is SHA256("WAM/RandomX/epoch-0/2026"), byte-reversed')

        self.log.info('the countdown agrees with the epoch it just reported')
        # The RPC answers for the block being built, one above the tip.
        assert_equal(info['height'] + info['blocks_until_rotation'] + 1, first_rotation)

        self.log.info(f'mining to one block below the rotation at {first_rotation}')
        self.generatetodescriptor(node, first_rotation - 2, ANYONE_CAN_SPEND)

        before = self.seed_info()
        assert_equal(before['height'], first_rotation - 2)
        assert_equal(before['bootstrap'], True)
        assert_equal(before['seed_height'], 0)

        # The RPC answers for the block being built, one above the tip, so the
        # countdown is always rotation_height - (tip + 1). Asserting the
        # invariant rather than a number keeps this correct on any network.
        assert_equal(before['height'] + before['blocks_until_rotation'] + 1, first_rotation)
        self.log.info(f'  height {before["height"]}: still bootstrap, '
                      f'{before["blocks_until_rotation"]} block to go')

        self.log.info('one more block, and the key changes')
        self.generatetodescriptor(node, 1, ANYONE_CAN_SPEND)

        after = self.seed_info()
        assert_equal(after['height'], first_rotation - 1)
        assert_equal(after['bootstrap'], False)
        assert_equal(after['seed_height'], seed_source)
        self.log.info(f'  height {after["height"]}: seeded from block {seed_source}')

        self.log.info('the new key is that block\'s hash, and nothing else')
        assert_equal(after['seed_hash'], node.getblockhash(seed_source))

        self.log.info('the key does not drift between rotations')
        self.generatetodescriptor(node, max(1, epoch // 4), ANYONE_CAN_SPEND)
        steady = self.seed_info()
        assert_equal(steady['seed_height'], seed_source)
        assert_equal(steady['seed_hash'], node.getblockhash(seed_source))

        self.log.info('and it rotates again exactly one epoch later')
        second_rotation = 2 * epoch + lag
        self.generatetodescriptor(
            node, second_rotation - 1 - steady['height'], ANYONE_CAN_SPEND)

        second = self.seed_info()
        assert_equal(second['height'], second_rotation - 1)
        assert_equal(second['seed_height'], 2 * epoch)
        assert_equal(second['seed_hash'], node.getblockhash(2 * epoch))
        self.log.info(f'  height {second["height"]}: seeded from block {2 * epoch}')

        self.log.info('getblocktemplate hands miners the same key as getrandomxinfo')
        # A pool reads the template; a human reads the info RPC. If those ever
        # disagree, every share the pool accepts is worthless.
        tmpl = node.getblocktemplate({'rules': ['segwit']})
        assert_equal(tmpl['randomx_seedhash'], second['seed_hash'])
        assert_equal(tmpl['randomx_seedheight'], second['seed_height'])

        self.log.info('the seed is buried exactly as deep as the lag promises')
        # The lag exists so that the block a key is derived from is already
        # settled. A seed taken from the tip would change under a one-block
        # reorg and split the network's mining between two keys.
        #
        # Measured from the block being mined, not from the tip. Every field
        # this RPC returns describes tip + 1, and getting that wrong is the
        # off-by-one this test made twice while being written. At the moment of
        # rotation the distance is exactly `lag`, never less, which is why this
        # is >= rather than >.
        next_height = second['height'] + 1
        depth = next_height - second['seed_height']
        assert_greater_than_or_equal(depth, lag)
        self.log.info(f'  block {next_height} is {depth} above its seed at '
                      f'{second["seed_height"]}, and the lag requires {lag}')


if __name__ == '__main__':
    WamRandomXEpochTest(__file__).main()

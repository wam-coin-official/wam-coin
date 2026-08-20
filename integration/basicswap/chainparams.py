# -*- coding: utf-8 -*-

# Copyright (c) 2026 The Basicswap developers
# Distributed under the MIT software license, see the accompanying
# file LICENSE or http://www.opensource.org/licenses/mit-license.php.

from basicswap.util import COIN

params = {
    "name": "wam",
    "ticker": "WAM",
    "message_magic": "WAM Coin Signed Message:\n",
    "blocks_target": 60 * 2,
    "decimal_places": 8,
    "mainnet": {
        "rpcport": 9554,
        "pubkey_address": 73,
        "script_address": 135,
        "key_prefix": 190,
        "hrp": "wam",
        # "bip44": <a registered SLIP-44 coin type>,
        #
        # Deliberately absent rather than invented. WAM has no SLIP-44
        # registration yet; a made-up number collides with a real coin and
        # derives every user's keys onto a path no other wallet will look at.
        # Registration is a pull request to satoshilabs/slips.
        "min_amount": 100000,
        "max_amount": 1000000 * COIN,
    },
    "testnet": {
        "rpcport": 19554,
        "pubkey_address": 65,
        "script_address": 128,
        "key_prefix": 239,
        "hrp": "twam",
        # "bip44": 1,
        "min_amount": 100000,
        "max_amount": 1000000 * COIN,
        "name": "testnet3",
    },
    "regtest": {
        "rpcport": 29554,
        "pubkey_address": 65,
        "script_address": 128,
        "key_prefix": 239,
        "hrp": "wamrt",
        # "bip44": 1,
        "min_amount": 100000,
        "max_amount": 1000000 * COIN,
    },
}

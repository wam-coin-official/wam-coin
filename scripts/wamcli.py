#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  wamcli.py -- how to address each chain with wam-cli, in one place
# ===========================================================================
#
#      from wamcli import flags
#      cmd = f"wam-cli {flags('mainnet')} getblockcount"
#
#  WHY THIS EXISTS
#
#  Six scripts carried their own copy of this line:
#
#      flag = {"mainnet": "", "testnet": "-testnet", "regtest": "-regtest"}[net]
#
#  An empty flag means "the default datadir", and on both WAM servers the
#  default datadir is /root/.wam -- whose wam.conf says testnet=1. So every one
#  of those scripts, asked to check MAINNET, silently queried the TESTNET node
#  and reported about the wrong chain with no hint that it had done so.
#
#  Found on 4 September 2026 during the Phase E rehearsal: a mainnet explorer
#  correctly showing height 0 was reported as "5054 blocks from the node",
#  because the node it asked was the testnet one. The six were:
#
#      check_bots.py  check_electrum.py  check_explorer.py
#      check_peer_versions.py  check_pool.py  check_visitors.py
#
#  Among them the check that says "everyone can follow mainnet" and the one
#  the runbook requires before a single share is credited. On launch night all
#  six would have answered confidently about testnet.
#
#  check_reorg.py had it right, alone, and that is the shape kept here.
#
#  WHY MAINNET NEEDS THREE FLAGS AND NOT ONE
#
#  -chain=main alone still reads the default datadir. The mainnet node lives in
#  /root/.wam-mainnet with its own wam.conf and its own RPC credentials, so the
#  conf and the datadir have to be named too. Omit them and wam-cli looks for
#  mainnet credentials in the testnet directory, finds none, and fails in a way
#  that reads like the node being down.
# ===========================================================================

MAINNET_DATADIR = "/root/.wam-mainnet"

_FLAGS = {
    "mainnet": f"-chain=main -conf={MAINNET_DATADIR}/wam.conf "
               f"-datadir={MAINNET_DATADIR}",
    "testnet": "-testnet",
    "regtest": "-regtest",
}


def flags(network, datadir=None):
    """The wam-cli flags that address one chain.

    datadir overrides the lot, for a throwaway chain in a temporary directory
    -- which is how a reorganisation can be caused on purpose without going
    anywhere near a node that matters.
    """
    if network not in _FLAGS:
        raise ValueError(f"unknown network: {network!r}")
    if datadir:
        short = {"mainnet": "-chain=main", "testnet": "-testnet",
                 "regtest": "-regtest"}[network]
        return f"{short} -datadir={datadir}"
    return _FLAGS[network]


def networks():
    return sorted(_FLAGS)

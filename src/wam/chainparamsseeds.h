// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.

#ifndef WAM_CHAINPARAMSSEEDS_H
#define WAM_CHAINPARAMSSEEDS_H

/**
 * Fixed seed nodes, in the compact BIP155 addrv2 serialization that
 * CChainParams::vFixedSeeds expects.
 *
 * ---------------------------------------------------------------------------
 * THIS FILE INTENTIONALLY DEFINES NOTHING.
 * ---------------------------------------------------------------------------
 *
 * Fixed seeds are a fallback used only when DNS seeding fails. Inventing
 * addresses for a chain that has not launched would produce nodes that spend
 * their first minutes dialling hosts which do not exist, so the arrays are
 * absent rather than empty.
 *
 * Note that "empty" is not an option in C++: upstream writes
 *
 *     vFixedSeeds = std::vector<uint8_t>(std::begin(chainparams_seed_main),
 *                                        std::end(chainparams_seed_main));
 *
 * and a zero-length array is not valid ISO C++ -- std::begin/std::end cannot
 * be applied to one. Declaring `chainparams_seed_main[] = {}` compiles under a
 * GCC extension but fails at those two call sites. kernel/chainparams.cpp
 * therefore calls vFixedSeeds.clear() for now.
 *
 * ---------------------------------------------------------------------------
 * TO POPULATE THIS FILE AFTER MAINNET HAS STABLE PEERS
 * ---------------------------------------------------------------------------
 *
 *   1. Collect real peers from a long-running node:
 *          wam-cli getnodeaddresses 0 > contrib/seeds/nodes_main.txt
 *   2. Regenerate:
 *          python3 contrib/seeds/generate-seeds.py contrib/seeds \
 *              > src/chainparamsseeds.h
 *   3. Restore the two commented-out lines in CMainParams (search for
 *      "No fixed seeds until mainnet has stable peers").
 *
 * Ship the result in a tagged release, never a hotfix: a bad fixed-seed list
 * is a network-partitioning vector.
 */

#endif // WAM_CHAINPARAMSSEEDS_H

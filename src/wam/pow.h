// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.

#ifndef WAM_POW_H
#define WAM_POW_H

#include <cstdint>

class CBlockIndex;
class CBlockHeader;
class uint256;
namespace Consensus { struct Params; }

namespace wam {

/**
 * DarkGravityWave v3 -- retargets on EVERY block.
 *
 * Rationale: WAM launches with a tiny hash rate. Bitcoin's 2016-block retarget
 * would let a rented gigahash farm mine a week's worth of blocks in an hour and
 * then leave the chain frozen at an unreachable difficulty for days. DGW
 * averages the last 24 block targets and rescales by the observed-versus-
 * expected timespan on every single block, so the chain absorbs a 100x hash
 * rate spike within roughly half an hour and recovers from its departure just
 * as fast.
 *
 * The observed timespan is clamped to [expected/3, expected*3] so that a miner
 * lying about timestamps (within the network's 2-hour future-time tolerance)
 * cannot drag difficulty more than 3x per block.
 *
 * @param pindexLast  tip the new block will build on (may be null on genesis)
 * @return            the compact (nBits) target the next block must satisfy
 */
unsigned int DarkGravityWave(const CBlockIndex* pindexLast, const Consensus::Params& params);

/**
 * Consensus entry point: the required nBits for the block following
 * `pindexLast`. Handles the regtest "no retargeting" escape hatch and the
 * bootstrap window before DGW has enough history, then delegates to
 * DarkGravityWave().
 */
unsigned int GetNextWorkRequired(const CBlockIndex* pindexLast,
                                 const CBlockHeader* pblock,
                                 const Consensus::Params& params);

/**
 * Verifies that `hash` (the RandomX PoW hash, NOT the double-SHA256 block id)
 * meets the target encoded in `nBits`, and that `nBits` is itself within the
 * network's proof-of-work limit.
 */
bool CheckProofOfWork(const uint256& hash, unsigned int nBits, const Consensus::Params& params);

} // namespace wam

#endif // WAM_POW_H

// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.

#ifndef WAM_CONSENSUS_SUBSIDY_H
#define WAM_CONSENSUS_SUBSIDY_H

#include <consensus/amount.h>

namespace Consensus { struct Params; }

namespace wam {

/**
 * Total amount created by the block at `nHeight`, before the treasury split.
 *
 *   height 0                    -> WAM_GENESIS_PREMINE (2,000,000 WAM)
 *   height 1 .. 200,000         -> 50 WAM
 *   height 200,001 .. 400,000   -> 25 WAM
 *   ...
 *   height > 6,600,000          -> 0
 *
 * The epoch index is computed from (nHeight - 1) so that the very first mined
 * block (height 1) opens epoch 0 and each epoch contains exactly
 * WAM_SUBSIDY_HALVING_INTERVAL blocks. Using nHeight directly, as Bitcoin
 * does, would put the genesis block inside epoch 0 and leave epoch 0 one block
 * short -- which would silently break the 20,000,000 WAM arithmetic.
 */
CAmount GetBlockSubsidy(int nHeight, const Consensus::Params& consensusParams);

/**
 * Portion of `nSubsidy` routed to the development treasury at `nHeight`.
 *
 * Returns 0 when:
 *   - nHeight is the genesis block (the premine is not split), or
 *   - nHeight > WAM_DEVFEE_LAST_HEIGHT -- the fee has sunset and miners take
 *     100% of the subsidy from then on, or
 *   - the subsidy has decayed so far that 5% truncates to zero.
 *
 * The height parameter is deliberately mandatory with no default. When the
 * sunset was introduced, a defaulted argument would have let every existing
 * call site keep compiling while silently computing the pre-sunset amount --
 * exactly the kind of change that ships a consensus bug.
 */
CAmount GetDevFeeAmount(CAmount nSubsidy, int nHeight);

/** Portion of `nSubsidy` payable to the miner at `nHeight`. */
CAmount GetMinerSubsidy(CAmount nSubsidy, int nHeight);

/**
 * True while the treasury fee is still collected, i.e.
 * WAM_DEVFEE_START_HEIGHT <= nHeight <= WAM_DEVFEE_LAST_HEIGHT.
 */
bool IsDevFeeActive(int nHeight);

/**
 * Total treasury income from block rewards over the life of the chain.
 * Computed rather than hard-coded, so the figure published in the whitepaper
 * and the figure the binary actually pays can never drift apart.
 */
CAmount GetLifetimeDevFee(const Consensus::Params& consensusParams);

/**
 * Amount of the founder reserve that is spendable at `nBlockTime`, given the
 * vesting schedule in wam-params.h. Used by `getsupplyinfo` so that anyone can
 * see the locked/unlocked split without decoding genesis scripts by hand.
 */
CAmount GetVestedPremine(int64_t nBlockTime);

/**
 * Cumulative supply in existence at (and including) `nHeight`.
 * Used by the `getsupplyinfo` RPC and by the unit tests that assert the
 * 22,000,000 WAM cap can never be reached.
 */
CAmount GetTotalSupplyAtHeight(int nHeight, const Consensus::Params& consensusParams);

} // namespace wam

#endif // WAM_CONSENSUS_SUBSIDY_H

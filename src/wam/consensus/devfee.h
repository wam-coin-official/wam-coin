// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.

#ifndef WAM_CONSENSUS_DEVFEE_H
#define WAM_CONSENSUS_DEVFEE_H

#include <consensus/amount.h>
#include <script/script.h>

#include <string>

class CTransaction;
class BlockValidationState;
namespace Consensus { struct Params; }

namespace wam {

/**
 * The locking script that every coinbase transaction must pay the treasury
 * portion to. Derived once from CChainParams::DevFeeAddress() and cached.
 */
const CScript& DevFeeScript(const Consensus::Params& consensusParams);

/**
 * Consensus rule WAM-1: mandatory treasury output.
 *
 * For every block at height in [WAM_DEVFEE_START_HEIGHT, WAM_DEVFEE_LAST_HEIGHT]
 * -- blocks 1 through 400,000 -- the coinbase transaction MUST contain at least
 * one output whose scriptPubKey is exactly DevFeeScript() and whose value is at
 * least GetDevFeeAmount(subsidy, nHeight).
 *
 * Outside that range the rule imposes nothing: from height 400,001 the fee has
 * sunset and miners keep 100% of the subsidy.
 *
 * "At least" rather than "exactly" is deliberate: a miner is free to donate
 * more, and pools that merge the treasury output with a change output would
 * otherwise be penalised. Paying less -- or omitting the output entirely --
 * makes the block invalid, which is what makes the 5% non-optional rather
 * than a social convention.
 *
 * Returns false and populates `state` with a `bad-cb-devfee-*` reject reason
 * on failure.
 */
bool CheckDevFeeOutput(const CTransaction& coinbase,
                       int nHeight,
                       CAmount nBlockSubsidy,
                       const Consensus::Params& consensusParams,
                       BlockValidationState& state);

/**
 * Total value paid to the treasury script by `coinbase`. Exposed for the
 * `getdevfeeinfo` RPC and for the block explorer / pool accounting layer.
 */
CAmount GetPaidDevFee(const CTransaction& coinbase, const Consensus::Params& consensusParams);

} // namespace wam

#endif // WAM_CONSENSUS_DEVFEE_H

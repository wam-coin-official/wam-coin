// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.

#include <wam/consensus/subsidy.h>

#include <consensus/params.h>
#include <wam/wam-params.h>

#include <algorithm>
#include <cassert>

namespace wam {

CAmount GetBlockSubsidy(int nHeight, const Consensus::Params& consensusParams)
{
    // Negative heights are never legitimate; treat them as "no subsidy" rather
    // than letting the signed division below wrap into a huge epoch index.
    if (nHeight < 0) return 0;

    // Block 0 mints the entire founder reserve in a single output. This is the
    // only place in the whole codebase where the premine can be created; the
    // amount is checked byte-for-byte against the genesis merkle root by
    // CChainParams, so it cannot be tampered with post-launch.
    if (nHeight == 0) return WAM_GENESIS_PREMINE;

    const int nInterval = consensusParams.nSubsidyHalvingInterval;
    assert(nInterval > 0);

    const int nHalvings = (nHeight - 1) / nInterval;

    // Guard against the undefined behaviour of shifting a 64-bit value by 64
    // or more, and terminate emission cleanly.
    if (nHalvings >= WAM_MAX_HALVINGS) return 0;

    CAmount nSubsidy = WAM_INITIAL_BLOCK_SUBSIDY;
    nSubsidy >>= nHalvings;
    return nSubsidy;
}

bool IsDevFeeActive(int nHeight)
{
    return nHeight >= WAM_DEVFEE_START_HEIGHT && nHeight <= WAM_DEVFEE_LAST_HEIGHT;
}

CAmount GetDevFeeAmount(CAmount nSubsidy, int nHeight)
{
    if (nSubsidy <= 0) return 0;

    // The sunset. From height 400,001 onward the treasury receives nothing and
    // the miner keeps the entire subsidy.
    if (!IsDevFeeActive(nHeight)) return 0;

    // Integer arithmetic only -- no floating point anywhere near consensus.
    // Multiplication before division keeps the truncation deterministic and
    // identical on every platform. nSubsidy is bounded by 50 * COIN, so the
    // intermediate product cannot overflow int64_t.
    return (nSubsidy * WAM_DEVFEE_PERCENT) / 100;
}

CAmount GetMinerSubsidy(CAmount nSubsidy, int nHeight)
{
    const CAmount nDevFee = GetDevFeeAmount(nSubsidy, nHeight);
    assert(nDevFee <= nSubsidy);
    return nSubsidy - nDevFee;
}

CAmount GetLifetimeDevFee(const Consensus::Params& consensusParams)
{
    const int nInterval = consensusParams.nSubsidyHalvingInterval;
    assert(nInterval > 0);

    CAmount nTotal = 0;

    // Epoch by epoch rather than height by height: the loop stays correct even
    // if the sunset is later moved far out, without becoming a million-step
    // iteration in a function the RPC layer calls.
    for (int epoch = 0; epoch < WAM_MAX_HALVINGS; ++epoch) {
        const CAmount nSubsidy = WAM_INITIAL_BLOCK_SUBSIDY >> epoch;
        if (nSubsidy == 0) break;

        const int nFirst = epoch * nInterval + 1;
        if (nFirst > WAM_DEVFEE_LAST_HEIGHT) break;

        // The epoch containing the sunset contributes only up to it.
        const int nLast = std::min((epoch + 1) * nInterval, WAM_DEVFEE_LAST_HEIGHT);
        const int nBlocks = nLast - nFirst + 1;

        nTotal += static_cast<CAmount>(nBlocks) * GetDevFeeAmount(nSubsidy, nFirst);
    }

    return nTotal;
}

CAmount GetVestedPremine(int64_t nBlockTime)
{
    CAmount nVested = 0;
    for (int i = 0; i < WAM_PREMINE_TRANCHES; ++i) {
        // A tranche with unlock time 0 is spendable from genesis; the rest
        // require the chain's median time past to have reached their deadline,
        // which is precisely what OP_CHECKLOCKTIMEVERIFY enforces on-chain.
        if (WAM_PREMINE_UNLOCK_TIMES[i] == 0 || nBlockTime >= WAM_PREMINE_UNLOCK_TIMES[i]) {
            nVested += WAM_PREMINE_TRANCHE_AMOUNT;
        }
    }
    return nVested;
}

CAmount GetTotalSupplyAtHeight(int nHeight, const Consensus::Params& consensusParams)
{
    if (nHeight < 0) return 0;

    const int nInterval = consensusParams.nSubsidyHalvingInterval;
    CAmount nSupply = WAM_GENESIS_PREMINE;

    // Sum whole epochs in closed form instead of iterating over millions of
    // heights: each complete epoch contributes nInterval * (50 WAM >> e).
    const int nCompletedEpochs = (nHeight >= 1) ? ((nHeight - 1) / nInterval) : 0;

    for (int e = 0; e < nCompletedEpochs && e < WAM_MAX_HALVINGS; ++e) {
        nSupply += static_cast<CAmount>(nInterval) * (WAM_INITIAL_BLOCK_SUBSIDY >> e);
    }

    // Then add the partial epoch the tip currently sits in.
    if (nHeight >= 1 && nCompletedEpochs < WAM_MAX_HALVINGS) {
        const int nBlocksIntoEpoch = ((nHeight - 1) % nInterval) + 1;
        nSupply += static_cast<CAmount>(nBlocksIntoEpoch)
                 * (WAM_INITIAL_BLOCK_SUBSIDY >> nCompletedEpochs);
    }

    assert(nSupply <= WAM_MAX_MONEY);
    return nSupply;
}

} // namespace wam

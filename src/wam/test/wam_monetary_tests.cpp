// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// Consensus-level tests for the WAM emission schedule.
//
// These run inside Bitcoin Core's Boost test harness:
//     ./src/test/test_wam --run_test=wam_monetary_tests
//
// The Python audit in scripts/verify_supply.py checks the same arithmetic from
// outside the codebase. Having both matters: the Python proves the *design* is
// sound, these prove the *shipped binary* implements that design.

#include <consensus/amount.h>
#include <consensus/params.h>
#include <test/util/setup_common.h>
#include <wam/consensus/subsidy.h>
#include <wam/wam-params.h>

#include <boost/test/unit_test.hpp>

using namespace wam;

BOOST_FIXTURE_TEST_SUITE(wam_monetary_tests, BasicTestingSetup)

namespace {
Consensus::Params MainnetLikeParams()
{
    Consensus::Params p;
    p.nSubsidyHalvingInterval = WAM_SUBSIDY_HALVING_INTERVAL;
    p.nInitialSubsidy = WAM_INITIAL_BLOCK_SUBSIDY;
    p.nGenesisPremine = WAM_GENESIS_PREMINE;
    p.nMaxMoney = WAM_MAX_MONEY;
    p.nDevFeePercent = WAM_DEVFEE_PERCENT;
    return p;
}
} // namespace

// ---------------------------------------------------------------------------

BOOST_AUTO_TEST_CASE(hard_cap_is_22_million)
{
    BOOST_CHECK_EQUAL(WAM_MAX_MONEY, 22'000'000LL * COIN);
    BOOST_CHECK_EQUAL(WAM_GENESIS_PREMINE, 2'000'000LL * COIN);
    BOOST_CHECK_EQUAL(WAM_MINING_ALLOCATION, 20'000'000LL * COIN);
    BOOST_CHECK_EQUAL(WAM_GENESIS_PREMINE + WAM_MINING_ALLOCATION, WAM_MAX_MONEY);

    // The identity that makes the numbers close exactly.
    BOOST_CHECK_EQUAL(static_cast<CAmount>(WAM_SUBSIDY_HALVING_INTERVAL)
                          * WAM_INITIAL_BLOCK_SUBSIDY * 2,
                      WAM_MINING_ALLOCATION);
}

BOOST_AUTO_TEST_CASE(genesis_mints_the_premine)
{
    const auto params = MainnetLikeParams();
    BOOST_CHECK_EQUAL(GetBlockSubsidy(0, params), WAM_GENESIS_PREMINE);
}

BOOST_AUTO_TEST_CASE(epoch_boundaries_are_exact)
{
    const auto params = MainnetLikeParams();
    const int I = WAM_SUBSIDY_HALVING_INTERVAL;

    // Epoch 0 must contain exactly I blocks: heights 1..200000.
    BOOST_CHECK_EQUAL(GetBlockSubsidy(1, params), 50 * COIN);
    BOOST_CHECK_EQUAL(GetBlockSubsidy(I, params), 50 * COIN);
    BOOST_CHECK_EQUAL(GetBlockSubsidy(I + 1, params), 25 * COIN);

    BOOST_CHECK_EQUAL(GetBlockSubsidy(2 * I, params), 25 * COIN);
    BOOST_CHECK_EQUAL(GetBlockSubsidy(2 * I + 1, params), 1250000000LL);
}

BOOST_AUTO_TEST_CASE(emission_terminates_cleanly)
{
    const auto params = MainnetLikeParams();
    const int I = WAM_SUBSIDY_HALVING_INTERVAL;

    BOOST_CHECK(GetBlockSubsidy(WAM_MAX_HALVINGS * I, params) >= 0);
    BOOST_CHECK_EQUAL(GetBlockSubsidy(WAM_MAX_HALVINGS * I + 1, params), 0);
    BOOST_CHECK_EQUAL(GetBlockSubsidy(100 * I, params), 0);

    // No undefined behaviour from an oversized shift.
    BOOST_CHECK_EQUAL(GetBlockSubsidy(1'000'000'000, params), 0);
}

BOOST_AUTO_TEST_CASE(negative_heights_are_harmless)
{
    const auto params = MainnetLikeParams();
    BOOST_CHECK_EQUAL(GetBlockSubsidy(-1, params), 0);
    BOOST_CHECK_EQUAL(GetBlockSubsidy(-1'000'000, params), 0);
}

BOOST_AUTO_TEST_CASE(total_emission_never_exceeds_the_cap)
{
    const auto params = MainnetLikeParams();
    const int I = WAM_SUBSIDY_HALVING_INTERVAL;

    // Sum every epoch in closed form -- iterating 6.6 million heights would
    // make the test suite unusably slow for no extra confidence.
    CAmount total = WAM_GENESIS_PREMINE;
    for (int epoch = 0; epoch < WAM_MAX_HALVINGS; ++epoch) {
        const CAmount subsidy = WAM_INITIAL_BLOCK_SUBSIDY >> epoch;
        total += static_cast<CAmount>(I) * subsidy;
    }

    BOOST_CHECK(total <= WAM_MAX_MONEY);
    BOOST_CHECK(MoneyRange(total));

    // Integer truncation costs us a little under a whole WAM; anything larger
    // would mean the shift arithmetic has drifted.
    BOOST_CHECK(WAM_MAX_MONEY - total < COIN);
}

BOOST_AUTO_TEST_CASE(cumulative_supply_matches_block_by_block_sum)
{
    const auto params = MainnetLikeParams();

    // Cross-check the closed-form helper against a literal accumulation over a
    // range that crosses two halvings.
    const int start = WAM_SUBSIDY_HALVING_INTERVAL - 5;
    const int end = WAM_SUBSIDY_HALVING_INTERVAL + 5;

    CAmount running = GetTotalSupplyAtHeight(start, params);
    for (int h = start + 1; h <= end; ++h) {
        running += GetBlockSubsidy(h, params);
        BOOST_CHECK_EQUAL(running, GetTotalSupplyAtHeight(h, params));
    }
}

// ---------------------------------------------------------------------------

BOOST_AUTO_TEST_CASE(dev_fee_is_carved_out_not_added)
{
    const CAmount subsidy = 50 * COIN;
    const CAmount devFee = GetDevFeeAmount(subsidy, 1);
    const CAmount miner = GetMinerSubsidy(subsidy, 1);

    BOOST_CHECK_EQUAL(devFee, 250000000LL);   // 2.5 WAM
    BOOST_CHECK_EQUAL(miner, 4750000000LL);   // 47.5 WAM

    // The invariant the whole hard cap depends on.
    BOOST_CHECK_EQUAL(miner + devFee, subsidy);
}

BOOST_AUTO_TEST_CASE(dev_fee_holds_at_every_height_it_applies_to)
{
    const auto params = MainnetLikeParams();

    for (int height : {1, 100, 199'999, 200'000, 200'001, 399'999, WAM_DEVFEE_LAST_HEIGHT}) {
        const CAmount subsidy = GetBlockSubsidy(height, params);
        const CAmount devFee = GetDevFeeAmount(subsidy, height);
        const CAmount miner = GetMinerSubsidy(subsidy, height);

        BOOST_CHECK_EQUAL(miner + devFee, subsidy);
        BOOST_CHECK(devFee <= subsidy);
        BOOST_CHECK(devFee >= 0);
        // Truncation must always favour the miner, never the treasury.
        BOOST_CHECK(devFee <= (subsidy * WAM_DEVFEE_PERCENT) / 100);
    }
}

// ---------------------------------------------------------------------------
// The sunset
// ---------------------------------------------------------------------------

BOOST_AUTO_TEST_CASE(dev_fee_window_boundaries)
{
    BOOST_CHECK(!IsDevFeeActive(0));                          // genesis
    BOOST_CHECK(IsDevFeeActive(WAM_DEVFEE_START_HEIGHT));      // 1
    BOOST_CHECK(IsDevFeeActive(WAM_DEVFEE_LAST_HEIGHT));       // 400,000
    BOOST_CHECK(!IsDevFeeActive(WAM_DEVFEE_LAST_HEIGHT + 1));  // 400,001
    BOOST_CHECK(!IsDevFeeActive(1'000'000));
}

BOOST_AUTO_TEST_CASE(miner_keeps_everything_after_the_sunset)
{
    const auto params = MainnetLikeParams();

    // The last block that pays the treasury...
    {
        const int h = WAM_DEVFEE_LAST_HEIGHT;
        const CAmount subsidy = GetBlockSubsidy(h, params);
        BOOST_CHECK_EQUAL(subsidy, 25 * COIN);
        BOOST_CHECK_EQUAL(GetDevFeeAmount(subsidy, h), 125000000LL);   // 1.25 WAM
        BOOST_CHECK_EQUAL(GetMinerSubsidy(subsidy, h), 2375000000LL);  // 23.75 WAM
    }

    // ...and the very next one, which pays it nothing.
    {
        const int h = WAM_DEVFEE_LAST_HEIGHT + 1;
        const CAmount subsidy = GetBlockSubsidy(h, params);
        BOOST_CHECK_EQUAL(GetDevFeeAmount(subsidy, h), 0);
        BOOST_CHECK_EQUAL(GetMinerSubsidy(subsidy, h), subsidy);
    }

    // Far past the sunset, at a height where 5% would still be a real amount
    // if the rule had not expired.
    {
        const int h = 1'000'000;
        const CAmount subsidy = GetBlockSubsidy(h, params);
        BOOST_CHECK(subsidy > 0);
        BOOST_CHECK_EQUAL(GetDevFeeAmount(subsidy, h), 0);
        BOOST_CHECK_EQUAL(GetMinerSubsidy(subsidy, h), subsidy);
    }
}

BOOST_AUTO_TEST_CASE(lifetime_dev_fee_matches_the_published_figure)
{
    const auto params = MainnetLikeParams();
    const CAmount lifetime = GetLifetimeDevFee(params);

    // 200,000 blocks x 2.5 WAM  +  200,000 blocks x 1.25 WAM
    BOOST_CHECK_EQUAL(lifetime, 750'000LL * COIN);

    // This is the number the whitepaper prints; keeping the assertion here
    // means the document and the binary cannot drift apart.
    const CAmount founderTotal = WAM_GENESIS_PREMINE + lifetime;
    BOOST_CHECK_EQUAL(founderTotal, 2'750'000LL * COIN);

    const double pct = 100.0 * static_cast<double>(founderTotal)
                             / static_cast<double>(WAM_MAX_MONEY);
    BOOST_CHECK_CLOSE(pct, 12.50, 0.01);

    // And it must never eat into the miners' allocation.
    BOOST_CHECK(lifetime < WAM_MINING_ALLOCATION);
}

BOOST_AUTO_TEST_CASE(dev_fee_of_zero_subsidy_is_zero)
{
    BOOST_CHECK_EQUAL(GetDevFeeAmount(0, 1), 0);
    BOOST_CHECK_EQUAL(GetDevFeeAmount(-1, 1), 0);
    BOOST_CHECK_EQUAL(GetMinerSubsidy(0, 1), 0);

    // Below 20 base units, 5% truncates to zero. Demanding a 0-value output
    // would only bloat the UTXO set.
    BOOST_CHECK_EQUAL(GetDevFeeAmount(19, 1), 0);
    BOOST_CHECK_EQUAL(GetDevFeeAmount(20, 1), 1);
}

// ---------------------------------------------------------------------------
// Founder reserve vesting
// ---------------------------------------------------------------------------

BOOST_AUTO_TEST_CASE(vesting_tranches_sum_to_the_premine)
{
    BOOST_CHECK_EQUAL(WAM_PREMINE_TRANCHES, 5);
    BOOST_CHECK_EQUAL(WAM_PREMINE_TRANCHE_AMOUNT, 400'000LL * COIN);
    BOOST_CHECK_EQUAL(WAM_PREMINE_TRANCHES * WAM_PREMINE_TRANCHE_AMOUNT,
                      WAM_GENESIS_PREMINE);
}

BOOST_AUTO_TEST_CASE(vesting_locks_are_timestamps_not_heights)
{
    // CLTV reads anything below 500,000,000 as a block height. A vesting
    // schedule that silently became "unlock at block 1,820,966,400" would
    // never release at all.
    //
    // This used to exempt index 0, which was the unlocked launch tranche. Every
    // tranche is locked now, so the rule applies to all of them without
    // exception -- and the exemption is what a future edit would most plausibly
    // reintroduce, so its absence is the thing being asserted.
    for (int i = 0; i < WAM_PREMINE_TRANCHES; ++i) {
        BOOST_CHECK(WAM_PREMINE_UNLOCK_TIMES[i] > 500'000'000);
        BOOST_CHECK(WAM_PREMINE_UNLOCK_TIMES[i] > WAM_GENESIS_TIME);
    }
    for (int i = 1; i < WAM_PREMINE_TRANCHES; ++i) {
        BOOST_CHECK(WAM_PREMINE_UNLOCK_TIMES[i] > WAM_PREMINE_UNLOCK_TIMES[i - 1]);
    }
}

BOOST_AUTO_TEST_CASE(vesting_releases_on_schedule)
{
    // At launch, nothing. This is the whole point of the reserve being locked:
    // on the day the chain starts, the founder holds 2,000,000 WAM and can
    // move none of it. The line used to read TRANCHE_AMOUNT, when the first
    // tranche was liquid.
    BOOST_CHECK_EQUAL(GetVestedPremine(WAM_GENESIS_TIME), 0);

    // A day before launch is meaningless but must not underflow into a
    // negative or wrap into the whole reserve.
    BOOST_CHECK_EQUAL(GetVestedPremine(WAM_GENESIS_TIME - 86400), 0);

    // One second before the first anniversary, still nothing.
    BOOST_CHECK_EQUAL(GetVestedPremine(WAM_PREMINE_UNLOCK_TIMES[0] - 1), 0);

    // Exactly on it, the first tranche and only that.
    BOOST_CHECK_EQUAL(GetVestedPremine(WAM_PREMINE_UNLOCK_TIMES[0]),
                      WAM_PREMINE_TRANCHE_AMOUNT);

    // And on the second, two.
    BOOST_CHECK_EQUAL(GetVestedPremine(WAM_PREMINE_UNLOCK_TIMES[1]),
                      2 * WAM_PREMINE_TRANCHE_AMOUNT);

    // After the final anniversary, the whole reserve.
    BOOST_CHECK_EQUAL(GetVestedPremine(WAM_PREMINE_UNLOCK_TIMES[WAM_PREMINE_TRANCHES - 1]),
                      WAM_GENESIS_PREMINE);
    BOOST_CHECK_EQUAL(GetVestedPremine(WAM_PREMINE_UNLOCK_TIMES[WAM_PREMINE_TRANCHES - 1]
                                       + 86400 * 365),
                      WAM_GENESIS_PREMINE);

    // Monotonic: vested value can never decrease as time moves forward.
    CAmount previous = 0;
    for (int64_t t = WAM_GENESIS_TIME;
         t <= WAM_PREMINE_UNLOCK_TIMES[WAM_PREMINE_TRANCHES - 1] + 86400;
         t += 86400 * 30) {
        const CAmount vested = GetVestedPremine(t);
        BOOST_CHECK(vested >= previous);
        BOOST_CHECK(vested <= WAM_GENESIS_PREMINE);
        previous = vested;
    }
}

BOOST_AUTO_TEST_SUITE_END()

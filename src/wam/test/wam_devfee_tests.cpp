// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// Consensus rule WAM-1: every coinbase must pay the development treasury.
//
//     ./src/test/test_wam --run_test=wam_devfee_tests
//
// These tests construct coinbase transactions by hand and assert exactly which
// ones CheckDevFeeOutput() accepts. A miner's incentive is to keep the whole
// subsidy, so the negative cases below are the ones that matter.

#include <chainparams.h>
#include <consensus/amount.h>
#include <consensus/params.h>
#include <consensus/validation.h>
#include <key_io.h>
#include <primitives/transaction.h>
#include <script/script.h>
#include <script/solver.h>
#include <test/util/setup_common.h>
#include <wam/consensus/devfee.h>
#include <wam/consensus/subsidy.h>
#include <wam/wam-params.h>

#include <boost/test/unit_test.hpp>

using namespace wam;

BOOST_FIXTURE_TEST_SUITE(wam_devfee_tests, BasicTestingSetup)

namespace {

/** A coinbase paying `devAmount` to `devScript` and the rest to `minerScript`. */
CMutableTransaction MakeCoinbase(const CScript& devScript, CAmount devAmount,
                                 const CScript& minerScript, CAmount minerAmount)
{
    CMutableTransaction tx;
    tx.version = 1;
    tx.vin.resize(1);
    tx.vin[0].prevout.SetNull();
    tx.vin[0].scriptSig = CScript() << OP_1 << OP_1;

    if (minerAmount > 0) {
        tx.vout.emplace_back(minerAmount, minerScript);
    }
    if (devAmount > 0) {
        tx.vout.emplace_back(devAmount, devScript);
    }
    return tx;
}

CScript DummyScript(unsigned char fill)
{
    return CScript() << OP_DUP << OP_HASH160
                     << std::vector<unsigned char>(20, fill)
                     << OP_EQUALVERIFY << OP_CHECKSIG;
}

} // namespace

// ---------------------------------------------------------------------------

BOOST_AUTO_TEST_CASE(genesis_is_exempt)
{
    const Consensus::Params& consensus = Params().GetConsensus();
    BlockValidationState state;

    // Block 0 IS the premine; there is nothing to split out of it.
    CMutableTransaction cb = MakeCoinbase(DummyScript(0xaa), 0,
                                          DummyScript(0xbb), WAM_GENESIS_PREMINE);
    BOOST_CHECK(CheckDevFeeOutput(CTransaction(cb), 0, WAM_GENESIS_PREMINE,
                                  consensus, state));
}

BOOST_AUTO_TEST_CASE(a_compliant_block_is_accepted)
{
    const Consensus::Params& consensus = Params().GetConsensus();
    const CScript& devScript = DevFeeScript(consensus);

    const CAmount subsidy = 50 * COIN;
    const CAmount required = GetDevFeeAmount(subsidy, 1);

    BlockValidationState state;
    CMutableTransaction cb = MakeCoinbase(devScript, required,
                                          DummyScript(0xbb), subsidy - required);

    BOOST_CHECK(CheckDevFeeOutput(CTransaction(cb), 1, subsidy, consensus, state));
    BOOST_CHECK_EQUAL(GetPaidDevFee(CTransaction(cb), consensus), required);
}

BOOST_AUTO_TEST_CASE(overpaying_the_treasury_is_allowed)
{
    // Deliberate: a pool that merges a change output into the treasury output,
    // or a miner who wants to donate, must not be penalised.
    const Consensus::Params& consensus = Params().GetConsensus();
    const CScript& devScript = DevFeeScript(consensus);

    const CAmount subsidy = 50 * COIN;
    const CAmount required = GetDevFeeAmount(subsidy, 1);

    BlockValidationState state;
    CMutableTransaction cb = MakeCoinbase(devScript, required * 2,
                                          DummyScript(0xbb), subsidy - required * 2);

    BOOST_CHECK(CheckDevFeeOutput(CTransaction(cb), 1, subsidy, consensus, state));
}

BOOST_AUTO_TEST_CASE(omitting_the_treasury_output_is_rejected)
{
    const Consensus::Params& consensus = Params().GetConsensus();
    const CAmount subsidy = 50 * COIN;

    BlockValidationState state;
    // The greedy miner: keep all 50 WAM.
    CMutableTransaction cb = MakeCoinbase(DummyScript(0xaa), 0,
                                          DummyScript(0xbb), subsidy);

    BOOST_CHECK(!CheckDevFeeOutput(CTransaction(cb), 1, subsidy, consensus, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-cb-devfee-amount");
}

BOOST_AUTO_TEST_CASE(underpaying_by_one_base_unit_is_rejected)
{
    const Consensus::Params& consensus = Params().GetConsensus();
    const CScript& devScript = DevFeeScript(consensus);

    const CAmount subsidy = 50 * COIN;
    const CAmount required = GetDevFeeAmount(subsidy, 1);

    BlockValidationState state;
    CMutableTransaction cb = MakeCoinbase(devScript, required - 1,
                                          DummyScript(0xbb), subsidy - required + 1);

    BOOST_CHECK(!CheckDevFeeOutput(CTransaction(cb), 1, subsidy, consensus, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-cb-devfee-amount");
}

BOOST_AUTO_TEST_CASE(paying_the_right_amount_to_the_wrong_script_is_rejected)
{
    // The subtle attack: a miner pays exactly 5%, but to an address they
    // control. Only a scriptPubKey comparison catches this.
    const Consensus::Params& consensus = Params().GetConsensus();

    const CAmount subsidy = 50 * COIN;
    const CAmount required = GetDevFeeAmount(subsidy, 1);

    BlockValidationState state;
    CMutableTransaction cb = MakeCoinbase(DummyScript(0xcc), required,
                                          DummyScript(0xbb), subsidy - required);

    BOOST_CHECK(!CheckDevFeeOutput(CTransaction(cb), 1, subsidy, consensus, state));
}

BOOST_AUTO_TEST_CASE(the_fee_may_be_split_across_several_outputs)
{
    const Consensus::Params& consensus = Params().GetConsensus();
    const CScript& devScript = DevFeeScript(consensus);

    const CAmount subsidy = 50 * COIN;
    const CAmount required = GetDevFeeAmount(subsidy, 1);

    CMutableTransaction cb;
    cb.version = 1;
    cb.vin.resize(1);
    cb.vin[0].prevout.SetNull();
    cb.vin[0].scriptSig = CScript() << OP_1 << OP_1;
    cb.vout.emplace_back(subsidy - required, DummyScript(0xbb));
    cb.vout.emplace_back(required / 2, devScript);
    cb.vout.emplace_back(required - required / 2, devScript);

    BlockValidationState state;
    BOOST_CHECK(CheckDevFeeOutput(CTransaction(cb), 1, subsidy, consensus, state));
    BOOST_CHECK_EQUAL(GetPaidDevFee(CTransaction(cb), consensus), required);
}

BOOST_AUTO_TEST_CASE(rule_is_skipped_once_the_fee_truncates_to_zero)
{
    const Consensus::Params& consensus = Params().GetConsensus();

    // A subsidy this small makes 5% round down to nothing; requiring a
    // 0-value output would only pollute the UTXO set.
    const CAmount tinySubsidy = 10;
    BOOST_CHECK_EQUAL(GetDevFeeAmount(tinySubsidy, 1), 0);

    BlockValidationState state;
    CMutableTransaction cb = MakeCoinbase(DummyScript(0xaa), 0,
                                          DummyScript(0xbb), tinySubsidy);
    BOOST_CHECK(CheckDevFeeOutput(CTransaction(cb), 6'000'000, tinySubsidy,
                                  consensus, state));
}

// ---------------------------------------------------------------------------
// The sunset -- rule WAM-1 stops applying after WAM_DEVFEE_LAST_HEIGHT
// ---------------------------------------------------------------------------

BOOST_AUTO_TEST_CASE(the_last_height_still_requires_the_treasury_output)
{
    const Consensus::Params& consensus = Params().GetConsensus();
    const CAmount subsidy = 25 * COIN;   // epoch 1, where height 400,000 sits
    const int height = WAM_DEVFEE_LAST_HEIGHT;

    // Omitting it here must still be fatal.
    BlockValidationState bad;
    CMutableTransaction greedy = MakeCoinbase(DummyScript(0xaa), 0,
                                              DummyScript(0xbb), subsidy);
    BOOST_CHECK(!CheckDevFeeOutput(CTransaction(greedy), height, subsidy, consensus, bad));
    BOOST_CHECK_EQUAL(bad.GetRejectReason(), "bad-cb-devfee-amount");

    // Paying it is accepted.
    const CAmount required = GetDevFeeAmount(subsidy, height);
    BOOST_CHECK_EQUAL(required, 125000000LL);   // 1.25 WAM

    BlockValidationState good;
    CMutableTransaction ok = MakeCoinbase(DevFeeScript(consensus), required,
                                          DummyScript(0xbb), subsidy - required);
    BOOST_CHECK(CheckDevFeeOutput(CTransaction(ok), height, subsidy, consensus, good));
}

BOOST_AUTO_TEST_CASE(one_block_after_the_sunset_the_miner_may_keep_everything)
{
    const Consensus::Params& consensus = Params().GetConsensus();
    const CAmount subsidy = 25 * COIN;
    const int height = WAM_DEVFEE_LAST_HEIGHT + 1;

    // The same coinbase that was invalid one block earlier is now valid.
    BlockValidationState state;
    CMutableTransaction cb = MakeCoinbase(DummyScript(0xaa), 0,
                                          DummyScript(0xbb), subsidy);
    BOOST_CHECK(CheckDevFeeOutput(CTransaction(cb), height, subsidy, consensus, state));
    BOOST_CHECK_EQUAL(GetDevFeeAmount(subsidy, height), 0);
}

BOOST_AUTO_TEST_CASE(paying_the_treasury_after_the_sunset_is_still_allowed)
{
    // The rule sets a floor, never a ceiling. A pool that keeps donating after
    // the sunset -- or simply never updates its config -- must not be forking
    // itself off the network.
    const Consensus::Params& consensus = Params().GetConsensus();
    const CAmount subsidy = 25 * COIN;
    const int height = WAM_DEVFEE_LAST_HEIGHT + 5000;

    BlockValidationState state;
    CMutableTransaction cb = MakeCoinbase(DevFeeScript(consensus), COIN,
                                          DummyScript(0xbb), subsidy - COIN);
    BOOST_CHECK(CheckDevFeeOutput(CTransaction(cb), height, subsidy, consensus, state));
}

BOOST_AUTO_TEST_CASE(the_sunset_is_far_enough_out_to_matter)
{
    // A guard against someone "tidying" the constant into uselessness: the fee
    // must span more than one halving epoch, or the published 750,000 WAM
    // figure in the whitepaper stops being true.
    BOOST_CHECK(WAM_DEVFEE_LAST_HEIGHT > WAM_SUBSIDY_HALVING_INTERVAL);
    BOOST_CHECK_EQUAL(WAM_DEVFEE_LAST_HEIGHT, 400'000);
}

BOOST_AUTO_TEST_CASE(an_empty_coinbase_is_rejected)
{
    const Consensus::Params& consensus = Params().GetConsensus();

    CMutableTransaction cb;
    cb.version = 1;
    cb.vin.resize(1);
    cb.vin[0].prevout.SetNull();
    cb.vin[0].scriptSig = CScript() << OP_1 << OP_1;
    // no outputs at all

    BlockValidationState state;
    BOOST_CHECK(!CheckDevFeeOutput(CTransaction(cb), 1, 50 * COIN, consensus, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-cb-devfee-missing");
}

BOOST_AUTO_TEST_SUITE_END()

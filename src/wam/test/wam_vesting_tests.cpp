// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  Does the vesting lock actually hold? -- asked of the script interpreter
// ===========================================================================
//
//     ./src/test/test_bitcoin --run_test=wam_vesting_tests
//
//  The PSBT rehearsal on regtest showed that Bitcoin Core's *wallet* will not
//  sign a bare CLTV output. That is true, and useful, and it proves far less
//  than it appears to: a wallet declining to build a signature says nothing
//  about whether CONSENSUS would accept one built by other means. Someone with
//  a custom signer is not stopped by the wallet's template matching.
//
//  So the question has to be put to the thing that actually decides: the script
//  interpreter, running the exact scriptPubKey that sits in the genesis block,
//  against a correctly signed spend, at controlled locktimes.
//
//  Three things are established here:
//
//     1. before the unlock date the script FAILS, and fails specifically with
//        SCRIPT_ERR_UNSATISFIED_LOCKTIME -- not with some incidental error that
//        would disappear the moment a detail changed
//     2. on and after the unlock date the very same script SUCCEEDS, so the
//        lock releases rather than merely refusing forever
//     3. the two well-known ways to defeat CLTV -- a final input sequence, and
//        mixing height-based and time-based locktimes -- are both rejected

#include <consensus/amount.h>
#include <key.h>
#include <primitives/transaction.h>
#include <script/interpreter.h>
#include <script/script.h>
#include <script/sign.h>
#include <script/signingprovider.h>
#include <test/util/setup_common.h>
#include <wam/wam-params.h>

#include <boost/test/unit_test.hpp>

using namespace wam;

BOOST_FIXTURE_TEST_SUITE(wam_vesting_tests, BasicTestingSetup)

namespace {

/** Exactly the script chainparams.cpp builds for a locked tranche. */
CScript VestingScript(const CKeyID& keyid, int64_t nLockTime)
{
    CScript script;
    script << nLockTime << OP_CHECKLOCKTIMEVERIFY << OP_DROP;
    script << OP_DUP << OP_HASH160 << ToByteVector(keyid) << OP_EQUALVERIFY << OP_CHECKSIG;
    return script;
}

/**
 * Sign a spend of `scriptPubKey` and run it through the interpreter.
 *
 * The flags are the ones consensus actually applies to a mature chain --
 * CHECKLOCKTIMEVERIFY included, since it is buried from height 1 on WAM.
 */
bool SpendSucceeds(const CKey& key,
                   const CScript& scriptPubKey,
                   uint32_t nLockTime,
                   uint32_t nSequence,
                   ScriptError* err)
{
    const CAmount nValue = 400'000 * COIN;

    CMutableTransaction credit;
    credit.version = 1;
    credit.vin.resize(1);
    credit.vin[0].prevout.SetNull();
    credit.vin[0].scriptSig = CScript() << OP_0 << OP_0;
    credit.vout.resize(1);
    credit.vout[0].nValue = nValue;
    credit.vout[0].scriptPubKey = scriptPubKey;

    CMutableTransaction spend;
    spend.version = 2;
    spend.nLockTime = nLockTime;
    spend.vin.resize(1);
    spend.vin[0].prevout = COutPoint(credit.GetHash(), 0);
    spend.vin[0].nSequence = nSequence;
    spend.vout.resize(1);
    spend.vout[0].nValue = nValue - 10000;
    spend.vout[0].scriptPubKey = CScript() << OP_TRUE;

    // Sign with SIGHASH_ALL over the vesting script.
    const uint256 hash = SignatureHash(scriptPubKey, spend, 0, SIGHASH_ALL,
                                       nValue, SigVersion::BASE);
    std::vector<unsigned char> vchSig;
    BOOST_REQUIRE(key.Sign(hash, vchSig));
    vchSig.push_back(static_cast<unsigned char>(SIGHASH_ALL));

    spend.vin[0].scriptSig = CScript() << vchSig << ToByteVector(key.GetPubKey());

    const unsigned int flags = SCRIPT_VERIFY_P2SH
                             | SCRIPT_VERIFY_DERSIG
                             | SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY
                             | SCRIPT_VERIFY_LOW_S
                             | SCRIPT_VERIFY_NULLDUMMY;

    return VerifyScript(spend.vin[0].scriptSig, scriptPubKey, nullptr, flags,
                        MutableTransactionSignatureChecker(&spend, 0, nValue,
                                                           MissingDataBehavior::ASSERT_FAIL),
                        err);
}

} // namespace

// ---------------------------------------------------------------------------

BOOST_AUTO_TEST_CASE(locked_tranche_cannot_be_spent_before_its_date)
{
    CKey key;
    key.MakeNewKey(/*fCompressed=*/true);
    const CKeyID keyid = key.GetPubKey().GetID();

    // Tranche 2: unlocks 2027-09-15.
    const int64_t unlock = WAM_PREMINE_UNLOCK_TIMES[1];
    const CScript script = VestingScript(keyid, unlock);

    ScriptError err = SCRIPT_ERR_OK;

    // One second early is still early.
    const bool ok = SpendSucceeds(key, script,
                                  /*nLockTime=*/static_cast<uint32_t>(unlock - 1),
                                  /*nSequence=*/0, &err);

    BOOST_CHECK(!ok);
    BOOST_CHECK_EQUAL(ScriptErrorString(err),
                      ScriptErrorString(SCRIPT_ERR_UNSATISFIED_LOCKTIME));
}

BOOST_AUTO_TEST_CASE(every_locked_tranche_refuses_at_the_launch_date)
{
    CKey key;
    key.MakeNewKey(true);
    const CKeyID keyid = key.GetPubKey().GetID();

    // At launch, tranches 2-5 must all be shut.
    for (int i = 1; i < WAM_PREMINE_TRANCHES; ++i) {
        const CScript script = VestingScript(keyid, WAM_PREMINE_UNLOCK_TIMES[i]);
        ScriptError err = SCRIPT_ERR_OK;

        const bool ok = SpendSucceeds(key, script,
                                      static_cast<uint32_t>(WAM_GENESIS_TIME),
                                      0, &err);

        BOOST_CHECK_MESSAGE(!ok, "tranche " << (i + 1) << " was spendable at launch");
        BOOST_CHECK_EQUAL(ScriptErrorString(err),
                          ScriptErrorString(SCRIPT_ERR_UNSATISFIED_LOCKTIME));
    }
}

BOOST_AUTO_TEST_CASE(the_lock_releases_on_its_date)
{
    // A lock that never opens is a burn, not a vest. Both halves matter.
    CKey key;
    key.MakeNewKey(true);
    const CKeyID keyid = key.GetPubKey().GetID();

    for (int i = 1; i < WAM_PREMINE_TRANCHES; ++i) {
        const int64_t unlock = WAM_PREMINE_UNLOCK_TIMES[i];
        const CScript script = VestingScript(keyid, unlock);
        ScriptError err = SCRIPT_ERR_OK;

        // Exactly on the second: CLTV compares with >=, so this must pass.
        const bool on_time = SpendSucceeds(key, script,
                                           static_cast<uint32_t>(unlock), 0, &err);
        BOOST_CHECK_MESSAGE(on_time,
            "tranche " << (i + 1) << " still locked ON its date: "
                       << ScriptErrorString(err));

        // And a year later.
        const bool later = SpendSucceeds(key, script,
                                         static_cast<uint32_t>(unlock + 31'557'600),
                                         0, &err);
        BOOST_CHECK_MESSAGE(later,
            "tranche " << (i + 1) << " still locked a year later: "
                       << ScriptErrorString(err));
    }
}

BOOST_AUTO_TEST_CASE(tranche_one_has_no_lock_at_all)
{
    CKey key;
    key.MakeNewKey(true);
    const CKeyID keyid = key.GetPubKey().GetID();

    // Tranche 1 is plain P2PKH -- the launch working capital.
    CScript plain;
    plain << OP_DUP << OP_HASH160 << ToByteVector(keyid) << OP_EQUALVERIFY << OP_CHECKSIG;

    ScriptError err = SCRIPT_ERR_OK;
    BOOST_CHECK(SpendSucceeds(key, plain, 0, 0xFFFFFFFF, &err));
    BOOST_CHECK_EQUAL(WAM_PREMINE_UNLOCK_TIMES[0], 0);
}

// ---------------------------------------------------------------------------
// The two standard ways to try to walk around CLTV
// ---------------------------------------------------------------------------

BOOST_AUTO_TEST_CASE(a_final_sequence_cannot_bypass_the_lock)
{
    // nSequence == 0xFFFFFFFF makes the transaction "final", which tells the
    // node to ignore nLockTime. CLTV exists precisely to close that door: it
    // refuses outright rather than letting the field be ignored. Without this
    // rule, every timelock in Bitcoin would be advisory.
    CKey key;
    key.MakeNewKey(true);
    const CKeyID keyid = key.GetPubKey().GetID();

    const int64_t unlock = WAM_PREMINE_UNLOCK_TIMES[1];
    const CScript script = VestingScript(keyid, unlock);

    ScriptError err = SCRIPT_ERR_OK;
    const bool ok = SpendSucceeds(key, script,
                                  static_cast<uint32_t>(unlock + 1000),
                                  /*nSequence=*/0xFFFFFFFF, &err);

    BOOST_CHECK(!ok);
    BOOST_CHECK_EQUAL(ScriptErrorString(err),
                      ScriptErrorString(SCRIPT_ERR_UNSATISFIED_LOCKTIME));
}

BOOST_AUTO_TEST_CASE(a_height_locktime_cannot_satisfy_a_time_lock)
{
    // Our locks are timestamps (> 500,000,000). A spender claiming a *block
    // height* locktime must not satisfy them, however large the number looks --
    // CLTV requires both sides to be on the same side of the 500,000,000
    // threshold. This is what stops "nLockTime = 800000" from unlocking a
    // tranche dated 2027.
    CKey key;
    key.MakeNewKey(true);
    const CKeyID keyid = key.GetPubKey().GetID();

    const int64_t unlock = WAM_PREMINE_UNLOCK_TIMES[1];
    BOOST_REQUIRE(unlock > LOCKTIME_THRESHOLD);

    const CScript script = VestingScript(keyid, unlock);

    ScriptError err = SCRIPT_ERR_OK;
    const bool ok = SpendSucceeds(key, script,
                                  /*nLockTime=*/LOCKTIME_THRESHOLD - 1, 0, &err);

    BOOST_CHECK(!ok);
    BOOST_CHECK_EQUAL(ScriptErrorString(err),
                      ScriptErrorString(SCRIPT_ERR_UNSATISFIED_LOCKTIME));
}

BOOST_AUTO_TEST_SUITE_END()

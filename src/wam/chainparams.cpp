// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// Drop-in replacement for Bitcoin Core's src/kernel/chainparams.cpp.
// Applied by scripts/apply-patches.sh; see patches/README.md.

#include <kernel/chainparams.h>

#include <base58.h>
#include <chainparamsseeds.h>
#include <consensus/amount.h>
#include <consensus/merkle.h>
#include <consensus/params.h>
#include <hash.h>
#include <primitives/block.h>
#include <primitives/transaction.h>
#include <script/interpreter.h>
#include <script/script.h>
#include <uint256.h>
#include <util/chaintype.h>
#include <util/strencodings.h>
#include <wam/wam-params.h>

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

using namespace wam;

// ===========================================================================
//  FOUNDER / TREASURY ADDRESS
// ===========================================================================
//
//  This address receives:
//    * the entire 2,000,000 WAM genesis premine, split across five vesting
//      tranches (one liquid, four behind OP_CHECKLOCKTIMEVERIFY), and
//    * 5% of every block subsidy from height 1 to WAM_DEVFEE_LAST_HEIGHT
//      (400,000) -- 750,000 WAM in total. The fee expires there; it is not
//      perpetual.
//
//  ---------------------------------------------------------------------------
//  THE VALUES BELOW ARE BURN ADDRESSES, NOT REAL ONES.
//  ---------------------------------------------------------------------------
//
//  Their hash160 is twenty zero bytes. Nobody holds the key -- finding one
//  would mean inverting RIPEMD160(SHA256(.)) -- so anything paid to them is
//  provably destroyed, and provably so to any observer, not just to us.
//
//  They are syntactically VALID on purpose. An earlier revision used the
//  literal string "WAM_FOUNDER_ADDRESS_PLACEHOLDER", which made
//  CChainParams::Main() throw from its constructor. That is the wrong shape of
//  guard: it did not merely stop a bad launch, it made mainnet parameters
//  impossible to construct at all -- so every unit test using the default
//  BasicTestingSetup fixture (which selects MAIN) aborted, and the consensus
//  code could not be verified before a key existed. A placeholder must stop the
//  NODE from launching, not stop the class from being built.
//
//  The build-time guard now lives in install.sh, which refuses to compile a
//  mainnet binary while these burn addresses are still present, and in
//  docs/LAUNCH_CHECKLIST.md phase 3.
//
//  Run
//      python3 scripts/gen_founder_key.py --network mainnet
//  on an OFFLINE machine, store the printed WIF in cold storage, and paste the
//  printed address here. install.sh refuses to build while the placeholder is
//  still present, so it is impossible to ship a binary that pays a dead
//  address by accident.
//
//  The corresponding private key must never appear in this repository, in any
//  build log, or in any chat transcript.
// ===========================================================================

// Generated 2026-08-17 by gen_founder_key.py on a live system running from RAM,
// with the network disabled, on a machine whose disk was never written to. The
// private key exists on paper and nowhere else: four handwritten copies, each
// one read back and checked against this address with --verify-backup while the
// screen still showed the original, before the machine was powered off.
//
// It has never been photographed, never typed into a networked device, and
// never transmitted to anyone.
static const std::string WAM_FOUNDER_ADDRESS_MAINNET = "WWWEvpC98mfzjRMZHtaRaucMjopqH2viQz";
// Testnet founder address, generated 2026-08-06. Testnet coins have no value,
// so this one was generated on an ordinary machine.
static const std::string WAM_FOUNDER_ADDRESS_TESTNET = "TK34fTbuMCXrwnmq72AE1EMMmdrkUtzUvq";

/**
 * Locking script for the founder address.
 *
 * This decodes base58check by hand rather than going through key_io's
 * DecodeDestination(). key_io resolves the address version bytes via
 * Params(), and Params() is exactly what is being constructed right now --
 * calling it here would be a use-before-initialisation that happens to work
 * on some builds and crashes on others. Decoding directly sidesteps that
 * entirely and needs no network context.
 *
 * A malformed or placeholder address throws, which stops the node from
 * starting. That is the desired behaviour: a chain whose premine and treasury
 * pay an invalid script would burn 2,000,000 WAM plus every treasury payment up
 * to height 400,000, and there is no way to undo it after launch.
 */
static std::vector<unsigned char> DecodeFounderHash(const std::string& address,
                                                    unsigned char& versionOut)
{
    std::vector<unsigned char> payload;

    if (!DecodeBase58Check(address, payload, 21) || payload.size() != 21) {
        throw std::runtime_error(
            "WAM: the founder address '" + address + "' is not a valid base58check "
            "address.\n"
            "Generate one on an offline machine with:\n"
            "    python3 scripts/gen_founder_key.py --network mainnet\n"
            "then set WAM_FOUNDER_ADDRESS_MAINNET in kernel/chainparams.cpp and mine a "
            "new genesis block with genesis/genesis_generator.py.");
    }

    versionOut = payload[0];
    return std::vector<unsigned char>(payload.begin() + 1, payload.end());
}

/** Plain P2PKH / P2SH script for the founder address. */
static CScript FounderPayToScript(const std::string& address)
{
    unsigned char version{0};
    const std::vector<unsigned char> hash = DecodeFounderHash(address, version);

    // P2PKH: OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
    if (version == 73 || version == 65) {
        return CScript() << OP_DUP << OP_HASH160 << hash << OP_EQUALVERIFY << OP_CHECKSIG;
    }
    // P2SH: OP_HASH160 <20 bytes> OP_EQUAL
    if (version == 135 || version == 128) {
        return CScript() << OP_HASH160 << hash << OP_EQUAL;
    }

    throw std::runtime_error(
        "WAM: founder address '" + address + "' has version byte " +
        std::to_string(version) + ", which is not a WAM address version "
        "(73/135 mainnet, 65/128 testnet).");
}

/**
 * Time-locked founder script:
 *
 *     <nLockTime> OP_CHECKLOCKTIMEVERIFY OP_DROP  <normal pay-to script>
 *
 * `nLockTime` is a Unix timestamp (every value used is far above 500,000,000,
 * which is what makes CLTV read it as a time rather than a block height).
 *
 * The lock is written BARE rather than wrapped in P2SH on purpose. A P2SH
 * output would publish only a hash, and a reader would have to trust a
 * separately distributed redeem script to know when the coins unlock. Bare, the
 * unlock date sits in the scriptPubKey where `wam-cli getblock <genesis> 2`
 * prints it -- the vesting schedule becomes self-evident from block 0 instead
 * of being a promise in a PDF.
 */
static CScript TimeLockedFounderScript(const std::string& address, int64_t nLockTime)
{
    if (nLockTime == 0) return FounderPayToScript(address);

    CScript script;
    script << nLockTime << OP_CHECKLOCKTIMEVERIFY << OP_DROP;

    const CScript payTo = FounderPayToScript(address);
    script.insert(script.end(), payTo.begin(), payTo.end());
    return script;
}

/**
 * The five founder-reserve outputs of the genesis coinbase.
 *
 * All five are time-locked; none is spendable at launch. They unlock on exact
 * calendar anniversaries of the launch date, one a year from 2027 to 2031, and
 * all five remain subject to the ordinary 100-block coinbase maturity as well.
 *
 * Operating money comes from the 5% treasury, which pays from block 1 and stops
 * at height 400,000 -- see WAM_DEVFEE_* in wam-params.h. The reserve is not
 * working capital and is not treated as any.
 */
static std::vector<CTxOut> BuildGenesisOutputs(const std::string& address)
{
    std::vector<CTxOut> outputs;
    outputs.reserve(WAM_PREMINE_TRANCHES);

    CAmount nTotal = 0;
    for (int i = 0; i < WAM_PREMINE_TRANCHES; ++i) {
        const int64_t nLockTime = WAM_PREMINE_UNLOCK_TIMES[i];
        outputs.emplace_back(WAM_PREMINE_TRANCHE_AMOUNT,
                             TimeLockedFounderScript(address, nLockTime));
        nTotal += WAM_PREMINE_TRANCHE_AMOUNT;
    }

    // Belt and braces alongside the static_assert in wam-params.h: if these
    // ever fail to sum to the premine, the genesis block silently mints the
    // wrong amount and the hard cap stops meaning anything.
    if (nTotal != WAM_GENESIS_PREMINE) {
        throw std::runtime_error("WAM: vesting tranches do not sum to the genesis premine");
    }

    return outputs;
}

/** Single-output genesis, used by regtest where vesting only gets in the way. */
static std::vector<CTxOut> SingleGenesisOutput(const CScript& script)
{
    return {CTxOut(WAM_GENESIS_PREMINE, script)};
}

/**
 * Build the genesis block.
 *
 * The coinbase input carries the launch phrase, which is committed into the
 * merkle root and therefore into the genesis hash: it is a permanent,
 * unforgeable proof that the chain was not created before the phrase existed.
 *
 * The outputs pay the 2,000,000 WAM founder reserve, split across the vesting
 * tranches. Note that in stock Bitcoin Core these outputs would be invisible to
 * the UTXO set and thus unspendable -- change WAM-005 fixes exactly that.
 */
static CBlock CreateGenesisBlock(const char* pszTimestamp,
                                 const std::vector<CTxOut>& genesisOutputs,
                                 uint32_t nTime,
                                 uint32_t nNonce,
                                 uint32_t nBits,
                                 int32_t nVersion)
{
    CMutableTransaction txNew;
    txNew.version = 1;
    txNew.vin.resize(1);
    txNew.vin[0].scriptSig = CScript()
        << 486604799
        << CScriptNum(4)
        << std::vector<unsigned char>((const unsigned char*)pszTimestamp,
                                      (const unsigned char*)pszTimestamp + strlen(pszTimestamp));
    txNew.vout = genesisOutputs;

    CBlock genesis;
    genesis.nTime    = nTime;
    genesis.nBits    = nBits;
    genesis.nNonce   = nNonce;
    genesis.nVersion = nVersion;
    genesis.vtx.push_back(MakeTransactionRef(std::move(txNew)));
    genesis.hashPrevBlock.SetNull();
    genesis.hashMerkleRoot = BlockMerkleRoot(genesis);
    return genesis;
}

static CBlock CreateGenesisBlock(uint32_t nTime, uint32_t nNonce, uint32_t nBits,
                                 int32_t nVersion,
                                 const std::vector<CTxOut>& genesisOutputs)
{
    return CreateGenesisBlock(WAM_GENESIS_TIMESTAMP_PHRASE, genesisOutputs,
                              nTime, nNonce, nBits, nVersion);
}

/**
 * ===========================================================================
 *  MAINNET
 * ===========================================================================
 */
class CMainParams : public CChainParams
{
public:
    CMainParams()
    {
        m_chain_type = ChainType::MAIN;

        // -------------------------------------------------------------------
        // Monetary policy -- every value traced back to wam/wam-params.h
        // -------------------------------------------------------------------
        consensus.nSubsidyHalvingInterval = WAM_SUBSIDY_HALVING_INTERVAL; // 200,000
        consensus.nInitialSubsidy         = WAM_INITIAL_BLOCK_SUBSIDY;    // 50 WAM
        consensus.nGenesisPremine         = WAM_GENESIS_PREMINE;          // 2,000,000 WAM
        consensus.nMaxMoney               = WAM_MAX_MONEY;                // 22,000,000 WAM
        consensus.nDevFeePercent          = WAM_DEVFEE_PERCENT;           // 5
        consensus.nDevFeeStartHeight      = WAM_DEVFEE_START_HEIGHT;      // 1
        consensus.nDevFeeLastHeight       = WAM_DEVFEE_LAST_HEIGHT;       // 400,000 (sunset)      // 1
        consensus.devFeeAddress           = WAM_FOUNDER_ADDRESS_MAINNET;
        consensus.nCoinbaseMaturity       = WAM_COINBASE_MATURITY;        // 100

        // -------------------------------------------------------------------
        // Proof of work -- RandomX + DarkGravityWave v3
        // -------------------------------------------------------------------
        //
        // powLimit is the *easiest* target the network will ever accept. It is
        // set so that a single modern CPU (~1.5 kH/s on RandomX) needs roughly
        // 10 minutes to find the first blocks; DGW then pulls difficulty up to
        // the real network hash rate within the first hour of life.
        consensus.powLimit = uint256S("00000fffff000000000000000000000000000000000000000000000000000000");

        consensus.nPowTargetSpacing  = WAM_POW_TARGET_SPACING; // 120 s
        consensus.nPowTargetTimespan = WAM_DGW_PAST_BLOCKS * WAM_POW_TARGET_SPACING;
        consensus.fPowAllowMinDifficultyBlocks = false;
        consensus.fPowNoRetargeting            = false;
        consensus.nDgwPastBlocks               = WAM_DGW_PAST_BLOCKS;
        consensus.nRandomXEpochBlocks          = WAM_RANDOMX_EPOCH_BLOCKS;
        consensus.nRandomXEpochLag             = WAM_RANDOMX_EPOCH_LAG;

        // -------------------------------------------------------------------
        // Deployments
        // -------------------------------------------------------------------
        //
        // WAM launches with BIP34/65/66, CSV, SegWit and Taproot active from
        // height 1. There is no legacy chain to be compatible with, so there
        // is no reason to inherit Bitcoin's decade of activation scaffolding
        // -- and every reason not to, since dormant activation code is where
        // consensus bugs hide.
        consensus.BIP34Height = 1;
        consensus.BIP34Hash   = uint256();
        consensus.BIP65Height = 1;
        consensus.BIP66Height = 1;
        consensus.CSVHeight   = 1;
        consensus.SegwitHeight = 1;
        consensus.MinBIP9WarningHeight = 0;

        consensus.nRuleChangeActivationThreshold = 1815; // 90% of 2016
        consensus.nMinerConfirmationWindow = 2016;

        consensus.vDeployments[Consensus::DEPLOYMENT_TESTDUMMY].bit = 28;
        consensus.vDeployments[Consensus::DEPLOYMENT_TESTDUMMY].nStartTime = Consensus::BIP9Deployment::NEVER_ACTIVE;
        consensus.vDeployments[Consensus::DEPLOYMENT_TESTDUMMY].nTimeout = Consensus::BIP9Deployment::NO_TIMEOUT;
        consensus.vDeployments[Consensus::DEPLOYMENT_TESTDUMMY].min_activation_height = 0;

        consensus.vDeployments[Consensus::DEPLOYMENT_TAPROOT].bit = 2;
        consensus.vDeployments[Consensus::DEPLOYMENT_TAPROOT].nStartTime = Consensus::BIP9Deployment::ALWAYS_ACTIVE;
        consensus.vDeployments[Consensus::DEPLOYMENT_TAPROOT].nTimeout = Consensus::BIP9Deployment::NO_TIMEOUT;
        consensus.vDeployments[Consensus::DEPLOYMENT_TAPROOT].min_activation_height = 0;

        // No trusted checkpoints at launch. These get populated by the
        // maintainers after the chain has real work behind it; shipping fake
        // ones now would be theatre.
        consensus.nMinimumChainWork = uint256{};
        consensus.defaultAssumeValid = uint256{};

        // -------------------------------------------------------------------
        // Network identity
        // -------------------------------------------------------------------
        pchMessageStart[0] = 0x57; // 'W'
        pchMessageStart[1] = 0x41; // 'A'
        pchMessageStart[2] = 0x4d; // 'M'
        pchMessageStart[3] = 0x21; // '!'
        nDefaultPort = WAM_MAINNET_P2P_PORT; // 9555

        nPruneAfterHeight = 100000;
        m_assumed_blockchain_size = 4;
        m_assumed_chain_state_size = 1;

        // -------------------------------------------------------------------
        // Genesis
        // -------------------------------------------------------------------
        //
        // nTime  : 2026-09-15 00:00:00 UTC
        // nBits  : 0x1e0ffff0, matching powLimit above
        // nNonce : mined 2026-08-18 by genesis/genesis_generator.py, 1,258,094
        //          RandomX hashes against the key "WAM/RandomX/epoch-0/2026".
        //
        // The merkle root below is the one check that proves the premine is
        // what it claims to be: it commits to all five outputs and their
        // scripts, so a schedule that does not match this root cannot produce
        // this block. It changed from 51e7dd7b when the first tranche was
        // locked, which is how that change was verified rather than trusted.
        genesis = CreateGenesisBlock(
            /*nTime=*/   WAM_GENESIS_TIME,   // 2026-09-15 00:00:00 UTC
            /*nNonce=*/  1264205,                 // <-- genesis_generator.py
            /*nBits=*/   0x1e0ffff0,
            /*nVersion=*/1,
            /*genesisOutputs=*/ BuildGenesisOutputs(WAM_FOUNDER_ADDRESS_MAINNET));

        consensus.hashGenesisBlock = genesis.GetHash();

        assert(consensus.hashGenesisBlock == uint256S("0xd8d3debea987b62a0934c3980d62bffbb6e16aa797d19891d4fcc9b9fb11d7e9"));
        assert(genesis.hashMerkleRoot     == uint256S("0x230fc579dfbad4cec208c43392e3178760fcd74617e4ef22903eae7bf7fcff29"));

        // -------------------------------------------------------------------
        // Peer discovery
        // -------------------------------------------------------------------
        vSeeds.clear();
        vSeeds.emplace_back("seed1.wamcoin.org.");
        vSeeds.emplace_back("seed2.wamcoin.org.");
        vSeeds.emplace_back("seed3.wamcoin.org.");

        // No fixed seeds until mainnet has stable, well-connected peers.
        //
        // Upstream writes
        //     vFixedSeeds = std::vector<uint8_t>(std::begin(chainparams_seed_main),
        //                                        std::end(chainparams_seed_main));
        // but a zero-length array is not valid ISO C++ and std::begin/std::end
        // do not apply to one, so that form cannot compile against an empty
        // seed list. Restore those two lines verbatim once
        // contrib/seeds/generate-seeds.py has produced a real
        // chainparamsseeds.h -- see that file's header comment.
        vFixedSeeds.clear();

        // -------------------------------------------------------------------
        // Address encoding -- version bytes verified by brute force, not guessed.
        // Every 20-byte hash under version 73 encodes to a base58 string
        // beginning with 'W'; see scripts/gen_founder_key.py --selftest.
        // -------------------------------------------------------------------
        base58Prefixes[PUBKEY_ADDRESS] = std::vector<unsigned char>(1, 73);  // 'W'
        base58Prefixes[SCRIPT_ADDRESS] = std::vector<unsigned char>(1, 135); // 'w'
        base58Prefixes[SECRET_KEY]     = std::vector<unsigned char>(1, 190); // 'V' / '7'
        base58Prefixes[EXT_PUBLIC_KEY] = {0x04, 0x88, 0xB2, 0x1E};
        base58Prefixes[EXT_SECRET_KEY] = {0x04, 0x88, 0xAD, 0xE4};

        bech32_hrp = "wam";

        // ------------------------------------------------------------------
        // Checkpoints
        // ------------------------------------------------------------------
        //
        // Exactly one entry: the genesis block. This is NOT a trust claim --
        // the genesis hash is already hardcoded three lines above in an
        // assert(), so checkpointing it asserts nothing new.
        //
        // It has to be here because CCheckpointData::GetHeight() is
        //
        //     return mapCheckpoints.rbegin()->first;
        //
        // and rbegin() on an EMPTY std::map decrements the end sentinel, which
        // is undefined behaviour. An earlier revision left this map empty on
        // the reasoning that inventing checkpoints before the chain exists
        // would be theatre. That reasoning was right; leaving the map empty was
        // not. init.cpp calls Checkpoints().GetHeight() while building the
        // help text for -checkpoints, so wamd segfaulted before it printed a
        // single line -- including on `wamd --version`.
        //
        // Real checkpoints get added in a later release, from a chain that has
        // actually accumulated work.
        checkpointData = {
            {
                {0, consensus.hashGenesisBlock},
            }
        };

        fDefaultConsistencyChecks = false;
        m_is_mockable_chain = false;

        chainTxData = ChainTxData{
            .nTime = 0,
            .tx_count = 0,
            .dTxRate = 0,
        };
    }
};

/**
 * ===========================================================================
 *  TESTNET
 * ===========================================================================
 */
class CTestNetParams : public CChainParams
{
public:
    CTestNetParams()
    {
        m_chain_type = ChainType::TESTNET;

        consensus.nSubsidyHalvingInterval = WAM_SUBSIDY_HALVING_INTERVAL;
        consensus.nInitialSubsidy         = WAM_INITIAL_BLOCK_SUBSIDY;
        consensus.nGenesisPremine         = WAM_GENESIS_PREMINE;
        consensus.nMaxMoney               = WAM_MAX_MONEY;
        consensus.nDevFeePercent          = WAM_DEVFEE_PERCENT;
        consensus.nDevFeeStartHeight      = WAM_DEVFEE_START_HEIGHT;      // 1
        consensus.nDevFeeLastHeight       = WAM_DEVFEE_LAST_HEIGHT;       // 400,000 (sunset)
        consensus.devFeeAddress           = WAM_FOUNDER_ADDRESS_TESTNET;
        consensus.nCoinbaseMaturity       = WAM_COINBASE_MATURITY;

        consensus.powLimit = uint256S("00000fffff000000000000000000000000000000000000000000000000000000");
        consensus.nPowTargetSpacing  = WAM_POW_TARGET_SPACING;
        consensus.nPowTargetTimespan = WAM_DGW_PAST_BLOCKS * WAM_POW_TARGET_SPACING;
        consensus.fPowAllowMinDifficultyBlocks = false;
        consensus.fPowNoRetargeting            = false;
        consensus.nDgwPastBlocks               = WAM_DGW_PAST_BLOCKS;

        // Short epochs on testnet so that the epoch-rollover path -- the single
        // most dangerous piece of the RandomX integration -- is exercised every
        // few hours instead of every few days.
        consensus.nRandomXEpochBlocks = 256;
        consensus.nRandomXEpochLag    = 16;

        consensus.BIP34Height = 1;
        consensus.BIP34Hash   = uint256();
        consensus.BIP65Height = 1;
        consensus.BIP66Height = 1;
        consensus.CSVHeight   = 1;
        consensus.SegwitHeight = 1;
        consensus.MinBIP9WarningHeight = 0;
        consensus.nRuleChangeActivationThreshold = 1512;
        consensus.nMinerConfirmationWindow = 2016;

        consensus.vDeployments[Consensus::DEPLOYMENT_TESTDUMMY].bit = 28;
        consensus.vDeployments[Consensus::DEPLOYMENT_TESTDUMMY].nStartTime = Consensus::BIP9Deployment::NEVER_ACTIVE;
        consensus.vDeployments[Consensus::DEPLOYMENT_TESTDUMMY].nTimeout = Consensus::BIP9Deployment::NO_TIMEOUT;
        consensus.vDeployments[Consensus::DEPLOYMENT_TESTDUMMY].min_activation_height = 0;
        consensus.vDeployments[Consensus::DEPLOYMENT_TAPROOT].bit = 2;
        consensus.vDeployments[Consensus::DEPLOYMENT_TAPROOT].nStartTime = Consensus::BIP9Deployment::ALWAYS_ACTIVE;
        consensus.vDeployments[Consensus::DEPLOYMENT_TAPROOT].nTimeout = Consensus::BIP9Deployment::NO_TIMEOUT;
        consensus.vDeployments[Consensus::DEPLOYMENT_TAPROOT].min_activation_height = 0;

        consensus.nMinimumChainWork = uint256{};
        consensus.defaultAssumeValid = uint256{};

        pchMessageStart[0] = 0x77; // 'w'
        pchMessageStart[1] = 0x61; // 'a'
        pchMessageStart[2] = 0x6d; // 'm'
        pchMessageStart[3] = 0x21; // '!'
        nDefaultPort = WAM_TESTNET_P2P_PORT; // 19555

        nPruneAfterHeight = 1000;
        m_assumed_blockchain_size = 1;
        m_assumed_chain_state_size = 1;

        genesis = CreateGenesisBlock(
            /*nTime=*/   WAM_TESTNET_GENESIS_TIME,   // 2026-08-01, ahead of mainnet
            /*nNonce=*/  2121580,             // <-- genesis_generator.py --network testnet
            /*nBits=*/   0x1e0ffff0,
            /*nVersion=*/1,
            /*genesisOutputs=*/ BuildGenesisOutputs(WAM_FOUNDER_ADDRESS_TESTNET));

        consensus.hashGenesisBlock = genesis.GetHash();

        assert(consensus.hashGenesisBlock == uint256S("0xb66685143044db0a6e35348ea51ca859c8143d9a1d2afe93ddf10b8caecac319"));
        assert(genesis.hashMerkleRoot     == uint256S("0x2b1469b34052506ab9425c98f9c3cddd19d1fdbcb2f6ace9f80fac42b0523f6e"));

        vFixedSeeds.clear();
        vSeeds.clear();
        vSeeds.emplace_back("testnet-seed.wamcoin.org.");

        base58Prefixes[PUBKEY_ADDRESS] = std::vector<unsigned char>(1, 65);  // 'T'
        base58Prefixes[SCRIPT_ADDRESS] = std::vector<unsigned char>(1, 128); // 't'
        base58Prefixes[SECRET_KEY]     = std::vector<unsigned char>(1, 239); // 'c'
        base58Prefixes[EXT_PUBLIC_KEY] = {0x04, 0x35, 0x87, 0xCF};
        base58Prefixes[EXT_SECRET_KEY] = {0x04, 0x35, 0x83, 0x94};

        bech32_hrp = "twam";

        // Genesis only -- see the comment in CMainParams. GetHeight() reads
        // rbegin(), so this map must never be empty.
        checkpointData = {
            {
                {0, consensus.hashGenesisBlock},
            }
        };

        fDefaultConsistencyChecks = false;
        m_is_mockable_chain = false;

        chainTxData = ChainTxData{0, 0, 0};
    }
};

/**
 * ===========================================================================
 *  REGTEST -- deterministic, instant-mining chain for the functional tests
 * ===========================================================================
 */
class CRegTestParams : public CChainParams
{
public:
    explicit CRegTestParams(const RegTestOptions& opts)
    {
        m_chain_type = ChainType::REGTEST;

        // A short halving interval keeps the emission tests fast while still
        // exercising the exact same code path as mainnet.
        //
        // Bitcoin Core v28's RegTestOptions carries only version_bits_parameters,
        // activation_heights and fastprune -- there is no configurable halving
        // interval to read from, so this is fixed here.
        consensus.nSubsidyHalvingInterval = 150;
        consensus.nInitialSubsidy         = WAM_INITIAL_BLOCK_SUBSIDY;
        consensus.nGenesisPremine         = WAM_GENESIS_PREMINE;
        consensus.nMaxMoney               = WAM_MAX_MONEY;
        consensus.nDevFeePercent          = WAM_DEVFEE_PERCENT;
        consensus.nDevFeeStartHeight      = WAM_DEVFEE_START_HEIGHT;      // 1
        consensus.nDevFeeLastHeight       = WAM_DEVFEE_LAST_HEIGHT;       // 400,000 (sunset)
        // A real, decodable address -- NOT an empty string.
        //
        // DevFeeScript() decodes this once and throws if it is not a valid WAM
        // address. An empty string therefore made every call throw, which broke
        // `getdevfeeinfo` outright and would have made CheckDevFeeOutput throw
        // while connecting any regtest block -- i.e. regtest mining could never
        // have worked. The original comment claimed "set by the test harness";
        // nothing set it.
        //
        // The testnet burn address (hash160 = 20 zero bytes) is used so regtest
        // exercises the identical code path as a live network while the coins
        // it pays are provably unspendable.
        consensus.devFeeAddress           = WAM_FOUNDER_ADDRESS_TESTNET;
        consensus.nCoinbaseMaturity       = 100;

        consensus.powLimit = uint256S("7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
        consensus.nPowTargetSpacing  = WAM_POW_TARGET_SPACING;
        consensus.nPowTargetTimespan = WAM_DGW_PAST_BLOCKS * WAM_POW_TARGET_SPACING;
        consensus.fPowAllowMinDifficultyBlocks = true;
        consensus.fPowNoRetargeting            = true;
        consensus.nDgwPastBlocks               = WAM_DGW_PAST_BLOCKS;
        consensus.nRandomXEpochBlocks          = 64;
        consensus.nRandomXEpochLag             = 4;

        consensus.BIP34Height = 1;
        consensus.BIP34Hash   = uint256();
        consensus.BIP65Height = 1;
        consensus.BIP66Height = 1;
        consensus.CSVHeight   = 1;
        consensus.SegwitHeight = 0;
        consensus.MinBIP9WarningHeight = 0;
        consensus.nRuleChangeActivationThreshold = 108;
        consensus.nMinerConfirmationWindow = 144;

        consensus.vDeployments[Consensus::DEPLOYMENT_TESTDUMMY].bit = 28;
        consensus.vDeployments[Consensus::DEPLOYMENT_TESTDUMMY].nStartTime = 0;
        consensus.vDeployments[Consensus::DEPLOYMENT_TESTDUMMY].nTimeout = Consensus::BIP9Deployment::NO_TIMEOUT;
        consensus.vDeployments[Consensus::DEPLOYMENT_TESTDUMMY].min_activation_height = 0;
        consensus.vDeployments[Consensus::DEPLOYMENT_TAPROOT].bit = 2;
        consensus.vDeployments[Consensus::DEPLOYMENT_TAPROOT].nStartTime = Consensus::BIP9Deployment::ALWAYS_ACTIVE;
        consensus.vDeployments[Consensus::DEPLOYMENT_TAPROOT].nTimeout = Consensus::BIP9Deployment::NO_TIMEOUT;
        consensus.vDeployments[Consensus::DEPLOYMENT_TAPROOT].min_activation_height = 0;

        for (const auto& [dep, height] : opts.activation_heights) {
            switch (dep) {
            case Consensus::BuriedDeployment::DEPLOYMENT_SEGWIT: consensus.SegwitHeight = int{height}; break;
            case Consensus::BuriedDeployment::DEPLOYMENT_HEIGHTINCB: consensus.BIP34Height = int{height}; break;
            case Consensus::BuriedDeployment::DEPLOYMENT_DERSIG: consensus.BIP66Height = int{height}; break;
            case Consensus::BuriedDeployment::DEPLOYMENT_CLTV: consensus.BIP65Height = int{height}; break;
            case Consensus::BuriedDeployment::DEPLOYMENT_CSV: consensus.CSVHeight = int{height}; break;
            }
        }

        // Kept in parity with upstream: the functional test framework drives
        // deployment activation through -vbparams, and dropping this loop would
        // make those tests silently pass against unactivated rules.
        for (const auto& [deployment_pos, version_bits_params] : opts.version_bits_parameters) {
            consensus.vDeployments[deployment_pos].nStartTime = version_bits_params.start_time;
            consensus.vDeployments[deployment_pos].nTimeout = version_bits_params.timeout;
            consensus.vDeployments[deployment_pos].min_activation_height = version_bits_params.min_activation_height;
        }

        consensus.nMinimumChainWork = uint256{};
        consensus.defaultAssumeValid = uint256{};

        pchMessageStart[0] = 0x57;
        pchMessageStart[1] = 0x41;
        pchMessageStart[2] = 0x4d;
        pchMessageStart[3] = 0x52; // 'R'
        nDefaultPort = WAM_REGTEST_P2P_PORT; // 29555

        nPruneAfterHeight = opts.fastprune ? 100 : 1000;
        m_assumed_blockchain_size = 0;
        m_assumed_chain_state_size = 0;

        // regtest carries the SAME five vesting tranches as mainnet.
        //
        // An earlier version used a bare OP_TRUE output so functional tests
        // could spend the premine trivially. That was convenient and wrong:
        // the vesting scripts are the part of the premine most likely to be
        // broken, and the only chain fast enough to actually exercise them was
        // the one chain that did not use them.
        //
        // regtest shares testnet's address version byte (65), so a testnet
        // founder address works here unchanged -- which means the offline
        // signing ritual can be rehearsed with the real key on a chain that
        // mines in milliseconds. `setmocktime` then lets a test jump past an
        // unlock date and prove the lock RELEASES, not merely that it holds.
        genesis = CreateGenesisBlock(
            /*nTime=*/   WAM_REGTEST_GENESIS_TIME,   // 2011 -- safely in the past
            /*nNonce=*/  1,
            /*nBits=*/   0x207fffff,
            /*nVersion=*/1,
            /*genesisOutputs=*/ BuildGenesisOutputs(WAM_FOUNDER_ADDRESS_TESTNET));

        consensus.hashGenesisBlock = genesis.GetHash();

        assert(consensus.hashGenesisBlock == uint256S("0x1fa171c2abc3cd0ba6d177524d23d63cc6ddeb4f08b20548c9b3d3c36ea6588b"));
        assert(genesis.hashMerkleRoot     == uint256S("0x2b1469b34052506ab9425c98f9c3cddd19d1fdbcb2f6ace9f80fac42b0523f6e"));

        vFixedSeeds.clear();
        vSeeds.clear();

        fDefaultConsistencyChecks = true;
        m_is_mockable_chain = true;

        base58Prefixes[PUBKEY_ADDRESS] = std::vector<unsigned char>(1, 65);
        base58Prefixes[SCRIPT_ADDRESS] = std::vector<unsigned char>(1, 128);
        base58Prefixes[SECRET_KEY]     = std::vector<unsigned char>(1, 239);
        base58Prefixes[EXT_PUBLIC_KEY] = {0x04, 0x35, 0x87, 0xCF};
        base58Prefixes[EXT_SECRET_KEY] = {0x04, 0x35, 0x83, 0x94};

        bech32_hrp = "wamrt";

        // Genesis only -- see the comment in CMainParams. GetHeight() reads
        // rbegin(), so this map must never be empty.
        checkpointData = {
            {
                {0, consensus.hashGenesisBlock},
            }
        };

        chainTxData = ChainTxData{0, 0, 0};
    }
};

std::unique_ptr<const CChainParams> CChainParams::RegTest(const RegTestOptions& options)
{
    return std::make_unique<const CRegTestParams>(options);
}

std::unique_ptr<const CChainParams> CChainParams::Main()
{
    return std::make_unique<const CMainParams>();
}

std::unique_ptr<const CChainParams> CChainParams::TestNet()
{
    return std::make_unique<const CTestNetParams>();
}

/**
 * ===========================================================================
 *  Networks WAM does not use
 * ===========================================================================
 *
 * Bitcoin Core v28 ships five networks: main, testnet3, testnet4, signet and
 * regtest. WAM uses three. The other two still need real definitions.
 *
 * An earlier revision made these throw, on the reasoning that a loud failure
 * beats silently placing an operator on the wrong chain. That was wrong, and
 * the unit tests caught it: SetupServerArgs() constructs EVERY chain type up
 * front in order to generate the help text for -port and -rpcport. Throwing
 * from here therefore did not merely reject `-signet` -- it aborted wamd
 * during argument setup, before it could parse a single option.
 *
 * The safe construction is a network that exists but is isolated: testnet's
 * parameters with a different P2P magic and port, and no seeds at all. A node
 * started with -signet or -testnet4 comes up on an empty network it cannot
 * confuse with any real one, because the differing magic makes the handshake
 * with a genuine WAM peer impossible.
 *
 * The genesis block is inherited unchanged from testnet, so its proof of work
 * is genuinely valid rather than a placeholder that would fail on first use.
 */
class CUnusedNetParams : public CTestNetParams
{
public:
    CUnusedNetParams(ChainType type, uint8_t magic_suffix, int port)
    {
        m_chain_type = type;

        // Same 'wam' prefix, distinct final byte: a peer on this network can
        // never complete a handshake with mainnet, testnet or regtest.
        pchMessageStart[3] = magic_suffix;
        nDefaultPort = port;

        // No discovery of any kind. These networks have no participants by
        // design, and pointing them at WAM's real seeds would be actively
        // harmful.
        vSeeds.clear();
        vFixedSeeds.clear();
    }
};

std::unique_ptr<const CChainParams> CChainParams::SigNet(const SigNetOptions& options)
{
    (void)options;   // WAM has no signet challenge to read
    return std::make_unique<const CUnusedNetParams>(ChainType::SIGNET, 0x53 /* 'S' */, 39555);
}

std::unique_ptr<const CChainParams> CChainParams::TestNet4()
{
    return std::make_unique<const CUnusedNetParams>(ChainType::TESTNET4, 0x34 /* '4' */, 49555);
}

/**
 * Snapshot (assumeutxo) heights. WAM ships none: an assumeutxo snapshot is a
 * hash of a UTXO set at a given height that the software asks users to trust,
 * and there is no honest way to publish one for a chain that has not run yet.
 * Returns empty until a release is cut from a real, long-lived chain.
 */
std::vector<int> CChainParams::GetAvailableSnapshotHeights() const
{
    std::vector<int> heights;
    heights.reserve(m_assumeutxo_data.size());
    for (const auto& data : m_assumeutxo_data) {
        heights.emplace_back(data.height);
    }
    return heights;
}

/**
 * Reverse-lookup of a network from its P2P message prefix.
 *
 * Deliberately checks only WAM's three networks. Upstream also probes
 * TestNet4() and SigNet(), which throw here -- and this function runs while
 * deserializing an untrusted UTXO snapshot header, where an exception would be
 * a denial-of-service rather than a diagnostic.
 */
std::optional<ChainType> GetNetworkForMagic(const MessageStartChars& message)
{
    const auto mainnet_msg = CChainParams::Main()->MessageStart();
    const auto testnet_msg = CChainParams::TestNet()->MessageStart();
    const auto regtest_msg = CChainParams::RegTest({})->MessageStart();

    if (std::equal(message.begin(), message.end(), mainnet_msg.data())) {
        return ChainType::MAIN;
    }
    if (std::equal(message.begin(), message.end(), testnet_msg.data())) {
        return ChainType::TESTNET;
    }
    if (std::equal(message.begin(), message.end(), regtest_msg.data())) {
        return ChainType::REGTEST;
    }
    return std::nullopt;
}

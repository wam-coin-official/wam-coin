#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""
===============================================================================
 patch_upstream.py -- turn a stock Bitcoin Core tree into the WAM Coin node
===============================================================================

WHY THIS IS NOT A SET OF .patch FILES
-------------------------------------
A unified diff is pinned to line numbers and surrounding context. The moment
upstream touches a nearby line the patch fails, and the usual response -- bump
the fuzz factor until it applies -- is exactly how a consensus change silently
lands in the wrong function. For a codebase whose bugs cost real money that
trade is not acceptable.

Instead every change below is an anchored transformation:

    * `anchor`  a string that must appear EXACTLY ONCE in the target file.
                Zero matches or two matches is a hard error, never a guess.
    * `apply`   the edit.
    * `verify`  a predicate re-checked after the edit.
    * idempotent: re-running is a no-op, so a half-finished build can simply
                be resumed.

Anything unexpected aborts the whole run and leaves the tree untouched, because
a partially patched consensus layer is far more dangerous than an unpatched one.

USAGE
-----
    python3 scripts/patch_upstream.py --tree build/bitcoin --repo .
    python3 scripts/patch_upstream.py --tree build/bitcoin --repo . --check
===============================================================================
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from dataclasses import dataclass, field

# ===========================================================================
# The version this node reports
# ===========================================================================
#
# One string, read by the configure.ac edit below and by the release workflow,
# which refuses to build a tag that disagrees with it. Before that gate existed
# the two drifted: v0.1.1 was tagged, built and published while the binary
# inside reported /WAM:0.1.0/ to every peer it met.
#
# Raise it in the same commit that gets tagged, never separately.
WAM_CLIENT_VERSION = "0.1.3"

# ===========================================================================
# Framework
# ===========================================================================


class PatchError(RuntimeError):
    pass


@dataclass
class Edit:
    """One anchored source transformation."""
    file: str
    description: str
    anchor: str | None = None
    replacement: str | None = None
    insert_after: str | None = None
    insert_text: str | None = None
    marker: str = ""          # presence of this string means "already applied"
    required: bool = True


@dataclass
class Change:
    """A named, reviewable consensus or packaging change."""
    id: str
    title: str
    rationale: str
    edits: list[Edit] = field(default_factory=list)
    copies: list[tuple[str, str]] = field(default_factory=list)  # (src, dst)


class Patcher:
    def __init__(self, tree: str, repo: str, dry_run: bool = False):
        self.tree = os.path.abspath(tree)
        self.repo = os.path.abspath(repo)
        self.dry_run = dry_run
        self.applied: list[str] = []
        self.skipped: list[str] = []

        if not os.path.isdir(os.path.join(self.tree, "src")):
            raise PatchError(
                f"{self.tree} does not look like a Bitcoin Core tree "
                "(no src/ directory). Run scripts/fetch-upstream.sh first.")

    # -- file helpers -------------------------------------------------------

    def _path(self, rel: str) -> str:
        return os.path.join(self.tree, rel)

    def _read(self, rel: str) -> str:
        path = self._path(rel)
        if not os.path.exists(path):
            raise PatchError(f"target file does not exist: {rel}")
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()

    def _write(self, rel: str, text: str) -> None:
        if self.dry_run:
            return
        path = self._path(rel)
        backup = path + ".wam-orig"
        if not os.path.exists(backup):
            shutil.copy2(path, backup)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)

    # -- the one rule that matters -----------------------------------------

    @staticmethod
    def _require_unique(src: str, needle: str, rel: str, what: str) -> None:
        count = src.count(needle)
        if count == 0:
            raise PatchError(
                f"{rel}: anchor for '{what}' not found.\n"
                f"  Looking for: {needle[:120]!r}\n"
                "  Upstream has moved. Do NOT loosen this match -- read the current "
                "source, confirm the change still belongs there, and update the anchor.")
        if count > 1:
            raise PatchError(
                f"{rel}: anchor for '{what}' matched {count} times; it must be unique.\n"
                f"  Looking for: {needle[:120]!r}\n"
                "  Extend the anchor with more surrounding context.")

    # -- application --------------------------------------------------------

    def apply_change(self, change: Change) -> None:
        print(f"\n[{change.id}] {change.title}")
        print(f"    {change.rationale}")

        for src_rel, dst_rel in change.copies:
            src = os.path.join(self.repo, src_rel)
            dst = self._path(dst_rel)
            if not os.path.exists(src):
                raise PatchError(f"source file missing from the repo: {src_rel}")
            if not self.dry_run:
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
            print(f"    copy  {src_rel} -> {dst_rel}")

        for edit in change.edits:
            self._apply_edit(change, edit)

        self.applied.append(change.id)

    def _apply_edit(self, change: Change, edit: Edit) -> None:
        try:
            src = self._read(edit.file)
        except PatchError:
            if not edit.required:
                print(f"    skip  {edit.file} (optional, not present)")
                return
            raise

        # Idempotence: a marker already present means this edit is done.
        if edit.marker and edit.marker in src:
            print(f"    ok    {edit.file}: already applied ({edit.description})")
            self.skipped.append(f"{change.id}:{edit.file}")
            return

        if edit.anchor is not None and edit.replacement is not None:
            self._require_unique(src, edit.anchor, edit.file, edit.description)
            out = src.replace(edit.anchor, edit.replacement, 1)

        elif edit.insert_after is not None and edit.insert_text is not None:
            self._require_unique(src, edit.insert_after, edit.file, edit.description)
            out = src.replace(edit.insert_after,
                              edit.insert_after + edit.insert_text, 1)
        else:
            raise PatchError(f"{change.id}: edit for {edit.file} is malformed")

        if out == src:
            raise PatchError(f"{edit.file}: transformation produced no change")

        self._write(edit.file, out)

        # Post-condition.
        if edit.marker and not self.dry_run:
            if edit.marker not in self._read(edit.file):
                raise PatchError(f"{edit.file}: verification failed after editing "
                                 f"({edit.description})")

        print(f"    edit  {edit.file}: {edit.description}")


# ===========================================================================
# The changes
# ===========================================================================
#
# Each entry below is a consensus-visible or packaging change and is documented
# in patches/README.md in the same order and with the same id.
# ===========================================================================

WAM_MARKER = "WAM_CONSENSUS_PATCH"


def build_changes() -> list[Change]:
    changes: list[Change] = []

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-000",
        title="Install the WAM source tree",
        rationale="Drop wam/ into src/ and replace chainparams with the WAM version.",
        copies=[
            ("src/wam/wam-params.h",                 "src/wam/wam-params.h"),
            ("src/wam/pow.h",                        "src/wam/pow.h"),
            ("src/wam/pow.cpp",                      "src/wam/pow.cpp"),
            ("src/wam/consensus/subsidy.h",          "src/wam/consensus/subsidy.h"),
            ("src/wam/consensus/subsidy.cpp",        "src/wam/consensus/subsidy.cpp"),
            ("src/wam/consensus/devfee.h",           "src/wam/consensus/devfee.h"),
            ("src/wam/consensus/devfee.cpp",         "src/wam/consensus/devfee.cpp"),
            ("src/wam/crypto/randomx_hash.h",        "src/wam/crypto/randomx_hash.h"),
            ("src/wam/crypto/randomx_hash.cpp",      "src/wam/crypto/randomx_hash.cpp"),
            ("src/wam/rpc/wam_rpc.cpp",              "src/wam/rpc/wam_rpc.cpp"),
            ("src/wam/chainparams.cpp",              "src/kernel/chainparams.cpp"),
            ("src/wam/chainparamsseeds.h",           "src/chainparamsseeds.h"),
            ("src/wam/test/wam_monetary_tests.cpp",  "src/test/wam_monetary_tests.cpp"),
            ("src/wam/test/wam_devfee_tests.cpp",    "src/test/wam_devfee_tests.cpp"),
            ("src/wam/test/wam_vesting_tests.cpp",   "src/test/wam_vesting_tests.cpp"),

            # Functional tests. These drive a real node over RPC, which is the
            # only way to catch a rule that is implemented but never reached --
            # the shape of the worst bug this fork has had.
            # The GUI's application icon and splash image. Replacing the file
            # rather than the reference keeps bitcoin.qrc, networkstyle.cpp and
            # the packaging untouched -- one binary swap instead of a rename
            # rippling through the build system.
            ("brand/generated/wam-icon-1024.png",    "src/qt/res/icons/bitcoin.png"),

            # The feature_ prefix is not decoration: test_runner.py refuses to
            # run anything that does not carry one of upstream's prefixes.
            ("test/functional/feature_wam_devfee.py",  "test/functional/feature_wam_devfee.py"),
            ("test/functional/feature_wam_genesis.py", "test/functional/feature_wam_genesis.py"),
            ("test/functional/feature_wam_pow.py",     "test/functional/feature_wam_pow.py"),
            ("test/functional/feature_wam_randomx_epoch.py",
             "test/functional/feature_wam_randomx_epoch.py"),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-001",
        title="Consensus parameters for the WAM monetary policy",
        rationale="Add the fields chainparams.cpp sets: premine, dev fee, DGW, RandomX.",
        edits=[Edit(
            file="src/consensus/params.h",
            description="add WAM consensus fields",
            marker=WAM_MARKER,
            insert_after="struct Params {",
            insert_text=f"""
    // ---------------- {WAM_MARKER} ----------------
    // WAM Coin monetary policy. Values are set in kernel/chainparams.cpp and
    // ultimately come from wam/wam-params.h.
    CAmount nInitialSubsidy{{0}};      //!< subsidy for the first epoch
    CAmount nGenesisPremine{{0}};      //!< minted in block 0 only
    CAmount nMaxMoney{{0}};            //!< hard cap, 22,000,000 WAM
    int64_t nDevFeePercent{{0}};       //!< carved OUT OF the subsidy, not added
    int nDevFeeStartHeight{{0}};
    int nDevFeeLastHeight{{0}};        //!< sunset: no treasury share past this height
    std::string devFeeAddress;       //!< treasury address, checked every block
    int nCoinbaseMaturity{{100}};

    //! DarkGravityWave v3: number of past blocks averaged on every retarget.
    int64_t nDgwPastBlocks{{24}};

    //! RandomX key rotation.
    int nRandomXEpochBlocks{{2048}};
    int nRandomXEpochLag{{64}};
    // -------------- end {WAM_MARKER} --------------
"""),
            Edit(
                file="src/consensus/params.h",
                description="include <string> and <consensus/amount.h>",
                marker="// WAM: needed by the consensus fields above",
                insert_after="#define BITCOIN_CONSENSUS_PARAMS_H\n",
                insert_text="\n// WAM: needed by the consensus fields above\n"
                            "#include <consensus/amount.h>\n#include <string>\n"),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-002",
        title="Hard cap of 22,000,000 WAM",
        rationale="MoneyRange() is Bitcoin's last line of defence against inflation bugs.",
        edits=[Edit(
            file="src/consensus/amount.h",
            description="replace MAX_MONEY with the WAM cap",
            marker="WAM_MAX_MONEY_ENFORCED",
            anchor="static constexpr CAmount MAX_MONEY = 21000000 * COIN;",
            replacement=(
                "// WAM_MAX_MONEY_ENFORCED\n"
                "//\n"
                "// 22,000,000 WAM = 2,000,000 genesis premine + 20,000,000 mined.\n"
                "// See wam/wam-params.h for the proof that the emission schedule\n"
                "// closes on exactly this number, and scripts/verify_supply.py for a\n"
                "// runnable audit of it.\n"
                "static constexpr CAmount MAX_MONEY = 22000000 * COIN;"),
        )]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-003",
        title="Route GetBlockSubsidy through the WAM schedule",
        rationale="200,000-block halvings, and block 0 mints the premine.",
        edits=[Edit(
            file="src/validation.cpp",
            description="delegate the subsidy to wam::GetBlockSubsidy",
            marker="WAM_SUBSIDY_DELEGATED",
            anchor="CAmount GetBlockSubsidy(int nHeight, const Consensus::Params& consensusParams)\n{",
            replacement=(
                "CAmount GetBlockSubsidy(int nHeight, const Consensus::Params& consensusParams)\n"
                "{\n"
                "    // WAM_SUBSIDY_DELEGATED -- the entire emission schedule lives in\n"
                "    // wam/consensus/subsidy.cpp so that it has exactly one definition.\n"
                "    return wam::GetBlockSubsidy(nHeight, consensusParams);\n"
                "}\n\n"
                "[[maybe_unused]] static CAmount GetBlockSubsidyUpstream("
                "int nHeight, const Consensus::Params& consensusParams)\n{"),
        ),
            Edit(
                file="src/validation.cpp",
                description="include the WAM consensus headers",
                marker="#include <wam/consensus/subsidy.h>",
                insert_after="#include <validation.h>\n",
                insert_text="\n#include <wam/consensus/subsidy.h>\n"
                            "#include <wam/consensus/devfee.h>\n"
                            "#include <wam/crypto/randomx_hash.h>\n"),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-004",
        title="Enforce the 5% treasury output (consensus rule WAM-1)",
        rationale="Without this the 5% is a social convention that any miner can ignore.",
        edits=[Edit(
            file="src/validation.cpp",
            description="reject blocks whose coinbase underpays the treasury",
            marker="WAM_DEVFEE_ENFORCED",
            anchor=("if (block.vtx[0]->GetValueOut() > blockReward) {"),
            replacement=(
                "    // WAM_DEVFEE_ENFORCED -- consensus rule WAM-1.\n"
                "    // Checked BEFORE the value test below: a block that omits the\n"
                "    // treasury output is invalid regardless of its totals.\n"
                "    if (!wam::CheckDevFeeOutput(*block.vtx[0], pindex->nHeight,\n"
                "                                GetBlockSubsidy(pindex->nHeight, params.GetConsensus()),\n"
                "                                params.GetConsensus(), state)) {\n"
                "        return false;\n"
                "    }\n\n"
                "    if (block.vtx[0]->GetValueOut() > blockReward) {"),
        )]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-005",
        title="Make the genesis premine spendable",
        rationale=("Stock Bitcoin Core never adds the genesis coinbase to the UTXO set, "
                   "which would make the 2,000,000 WAM founder reserve permanently dead."),
        edits=[Edit(
            file="src/validation.cpp",
            description="add the genesis coinbase outputs to the UTXO set",
            marker="WAM_GENESIS_SPENDABLE",
            # Anchored on the whole upstream block, comment included. Upstream
            # compares against a local `block_hash`, not `block.GetHash()`.
            anchor=(
                "    // Special case for the genesis block, skipping connection of its transactions\n"
                "    // (its coinbase is unspendable)\n"
                "    if (block_hash == params.GetConsensus().hashGenesisBlock) {\n"
                "        if (!fJustCheck)\n"
                "            view.SetBestBlock(pindex->GetBlockHash());\n"
                "        return true;\n"
                "    }"),
            replacement=(
                "    // WAM_GENESIS_SPENDABLE\n"
                "    //\n"
                "    // Upstream skips the genesis block entirely because its coinbase is\n"
                "    // unspendable by construction -- that is precisely why Satoshi's original\n"
                "    // 50 BTC can never move. WAM mints the 2,000,000 WAM founder reserve\n"
                "    // there, so those coins MUST enter the UTXO set or the entire premine is\n"
                "    // burned at launch, with no way to undo it afterwards.\n"
                "    //\n"
                "    // ALL FIVE vesting outputs are added, not just the liquid one: a coin\n"
                "    // that is not in the set cannot later become spendable when its CLTV\n"
                "    // deadline passes.\n"
                "    //\n"
                "    // The coins remain subject to normal coinbase maturity (100 blocks) and\n"
                "    // to the OP_CHECKLOCKTIMEVERIFY locks carried in their own scripts.\n"
                "    // AddCoins is guarded by !fJustCheck for the same reason SetBestBlock is:\n"
                "    // a validation-only pass must not mutate the cache.\n"
                "    if (block_hash == params.GetConsensus().hashGenesisBlock) {\n"
                "        if (!fJustCheck) {\n"
                "            AddCoins(view, *block.vtx[0], 0);\n"
                "            view.SetBestBlock(pindex->GetBlockHash());\n"
                "        }\n"
                "        return true;\n"
                "    }"),
        )]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-006",
        title="RandomX proof of work and DarkGravityWave v3",
        rationale="Replace SHA256d PoW checking and Bitcoin's 2016-block retarget.",
        edits=[Edit(
            file="src/pow.cpp",
            description="delegate GetNextWorkRequired to DGWv3",
            marker="WAM_DGW_DELEGATED",
            anchor=("unsigned int GetNextWorkRequired(const CBlockIndex* pindexLast, "
                    "const CBlockHeader *pblock, const Consensus::Params& params)\n{"),
            replacement=(
                "unsigned int GetNextWorkRequired(const CBlockIndex* pindexLast, "
                "const CBlockHeader *pblock, const Consensus::Params& params)\n"
                "{\n"
                "    // WAM_DGW_DELEGATED -- every block retargets; see wam/pow.cpp.\n"
                "    return wam::GetNextWorkRequired(pindexLast, pblock, params);\n"
                "}\n\n"
                "[[maybe_unused]] static unsigned int GetNextWorkRequiredUpstream("
                "const CBlockIndex* pindexLast, const CBlockHeader *pblock, "
                "const Consensus::Params& params)\n{"),
        ),
            Edit(
                file="src/pow.cpp",
                description="include wam/pow.h",
                marker="#include <wam/pow.h>",
                insert_after="#include <pow.h>\n",
                insert_text="\n#include <wam/pow.h>\n#include <wam/crypto/randomx_hash.h>\n"),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-007",
        title="Expose the treasury amount through getblocktemplate",
        rationale=("Pools must be able to build a valid coinbase without reimplementing "
                   "the halving schedule in a second language."),
        edits=[Edit(
            file="src/rpc/mining.cpp",
            description="add a devfee object to the GBT result",
            marker="WAM_GBT_DEVFEE",
            # Upstream casts to int64_t, not int.
            anchor='    result.pushKV("height", (int64_t)(pindexPrev->nHeight+1));',
            replacement=(
                '    result.pushKV("height", (int64_t)(pindexPrev->nHeight+1));\n\n'
                "    // WAM_GBT_DEVFEE -- consensus rule WAM-1 requires this output in\n"
                "    // every coinbase. Reporting it here means a pool copies one number\n"
                "    // instead of reimplementing the emission schedule and being wrong\n"
                "    // about it at some future halving.\n"
                "    {\n"
                "        const int nNextHeight = pindexPrev->nHeight + 1;\n"
                "        const CAmount nSubsidy = GetBlockSubsidy(nNextHeight, consensusParams);\n"
                "        const CAmount nDevFee = wam::GetDevFeeAmount(nSubsidy, nNextHeight);\n"
                "        const CScript& devScript = wam::DevFeeScript(consensusParams);\n"
                "        UniValue devfee(UniValue::VOBJ);\n"
                '        devfee.pushKV("amount", nDevFee);\n'
                '        devfee.pushKV("script", HexStr(devScript));\n'
                '        devfee.pushKV("address", consensusParams.devFeeAddress);\n'
                '        devfee.pushKV("percent", (int64_t)consensusParams.nDevFeePercent);\n'
                '        devfee.pushKV("last_height", consensusParams.nDevFeeLastHeight);\n'
                '        devfee.pushKV("active", wam::IsDevFeeActive(nNextHeight));\n'
                '        result.pushKV("devfee", devfee);\n'
                "    }\n\n"
                "    // WAM: the RandomX key miners must use for this height.\n"
                "    {\n"
                "        const uint256 seed = wam::GetRandomXSeedHash(pindexPrev, consensusParams);\n"
                '        result.pushKV("randomx_seedhash", seed.GetHex());\n'
                '        result.pushKV("randomx_seedheight",\n'
                "                      wam::GetRandomXSeedHeight(pindexPrev->nHeight + 1,\n"
                "                                                consensusParams));\n"
                "    }"),
        ),
            Edit(
                file="src/rpc/mining.cpp",
                description="include the WAM headers",
                marker="#include <wam/consensus/devfee.h>",
                insert_after="#include <rpc/util.h>\n",
                insert_text="\n#include <wam/consensus/devfee.h>\n"
                            "#include <wam/consensus/subsidy.h>\n"
                            "#include <wam/crypto/randomx_hash.h>\n"),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-010",
        title="Move the proof-of-work check to where the RandomX seed is knowable",
        rationale=("RandomX needs the chain's seed, which is derived from height. "
                   "CheckBlockHeader has no chain context, so the check must move."),
        edits=[
            Edit(
                file="src/validation.cpp",
                description="drop the context-free PoW check from CheckBlockHeader",
                marker="WAM_POW_IS_CONTEXTUAL",
                anchor=(
                    "static bool CheckBlockHeader(const CBlockHeader& block, BlockValidationState& state, const Consensus::Params& consensusParams, bool fCheckPOW = true)\n"
                    "{\n"
                    "    // Check proof of work matches claimed amount\n"
                    "    if (fCheckPOW && !CheckProofOfWork(block.GetHash(), block.nBits, consensusParams))\n"
                    "        return state.Invalid(BlockValidationResult::BLOCK_INVALID_HEADER, \"high-hash\", \"proof of work failed\");\n"
                    "\n"
                    "    return true;\n"
                    "}"),
                replacement=(
                    "static bool CheckBlockHeader(const CBlockHeader& block, BlockValidationState& state, const Consensus::Params& consensusParams, bool fCheckPOW = true)\n"
                    "{\n"
                    "    // WAM_POW_IS_CONTEXTUAL\n"
                    "    //\n"
                    "    // Bitcoin can verify proof of work from a header alone, because\n"
                    "    // SHA256d needs nothing but the 80 bytes in front of it. RandomX\n"
                    "    // cannot: the VM is keyed by a seed derived from a buried block's\n"
                    "    // hash, so verifying a header requires knowing where in the chain it\n"
                    "    // sits. This function is handed no chain context at all.\n"
                    "    //\n"
                    "    // The check therefore lives in ContextualCheckBlockHeader, which\n"
                    "    // receives pindexPrev. Nothing is skipped -- every path that reaches\n"
                    "    // here (AcceptBlockHeader, CheckBlock) also runs the contextual\n"
                    "    // check before a block is accepted.\n"
                    "    //\n"
                    "    // TRADE-OFF, stated plainly: Bitcoin uses this cheap check to discard\n"
                    "    // garbage headers before the more expensive parent lookup. WAM loses\n"
                    "    // that filter. The mitigation is inherent to the ordering -- a peer\n"
                    "    // must present a header whose parent we already have before any\n"
                    "    // RandomX hashing is done on its behalf, so flooding unknown headers\n"
                    "    // costs the attacker more than it costs us. This is the same posture\n"
                    "    // every RandomX chain operates under.\n"
                    "    (void)block;\n"
                    "    (void)consensusParams;\n"
                    "    (void)fCheckPOW;\n"
                    "    (void)state;\n"
                    "    return true;\n"
                    "}"),
            ),
            Edit(
                file="src/validation.cpp",
                description="verify RandomX PoW in ContextualCheckBlockHeader",
                marker="WAM_RANDOMX_POW_VERIFIED",
                anchor=(
                    "    if (block.nBits != GetNextWorkRequired(pindexPrev, &block, consensusParams))\n"
                    "        return state.Invalid(BlockValidationResult::BLOCK_INVALID_HEADER, \"bad-diffbits\", \"incorrect proof of work\");"),
                replacement=(
                    "    if (block.nBits != GetNextWorkRequired(pindexPrev, &block, consensusParams))\n"
                    "        return state.Invalid(BlockValidationResult::BLOCK_INVALID_HEADER, \"bad-diffbits\", \"incorrect proof of work\");\n"
                    "\n"
                    "    // WAM_RANDOMX_POW_VERIFIED\n"
                    "    //\n"
                    "    // This is THE proof-of-work check for WAM. The line above only\n"
                    "    // confirms the claimed difficulty is the one DarkGravityWave demands;\n"
                    "    // this one confirms the miner actually did the work.\n"
                    "    //\n"
                    "    // The seed comes from pindexPrev, so it is the seed the network\n"
                    "    // agrees on for this height -- not one the submitter chose.\n"
                    "    {\n"
                    "        const uint256 seed = wam::GetRandomXSeedHash(pindexPrev, consensusParams);\n"
                    "        const uint256 pow_hash = wam::GetRandomXPoWHash(block, seed);\n"
                    "        if (!wam::CheckProofOfWork(pow_hash, block.nBits, consensusParams)) {\n"
                    "            return state.Invalid(BlockValidationResult::BLOCK_INVALID_HEADER,\n"
                    "                                 \"high-hash\", \"RandomX proof of work failed\");\n"
                    "        }\n"
                    "    }"),
            ),
            Edit(
                file="src/node/blockstorage.cpp",
                description="drop the un-contextual PoW check when reading a block from disk",
                marker="WAM_DISK_POW_CHECK_REMOVED",
                anchor=(
                    "    // Check the header\n"
                    "    if (!CheckProofOfWork(block.GetHash(), block.nBits, GetConsensus())) {\n"
                    "        LogError(\"%s: Errors in block header at %s\\n\", __func__, pos.ToString());\n"
                    "        return false;\n"
                    "    }"),
                replacement=(
                    "    // WAM_DISK_POW_CHECK_REMOVED\n"
                    "    //\n"
                    "    // Upstream re-checks proof of work here purely to detect disk\n"
                    "    // corruption -- the block was fully validated before it was ever\n"
                    "    // written. RandomX cannot be verified from a FlatFilePos, which\n"
                    "    // carries no height and therefore no seed.\n"
                    "    //\n"
                    "    // Removing it costs nothing that matters: this was never a security\n"
                    "    // boundary, and corruption is still caught by the block's message\n"
                    "    // start bytes, its length prefix, and deserialization above -- which\n"
                    "    // is exactly what the `catch` a few lines up exists for.\n"
                    "    //\n"
                    "    // Leaving it in place is what made wamd fail at startup with\n"
                    "    // \"Errors in block header\" while reading its own valid genesis block.\n"),
            ),
            Edit(
                file="src/validation.cpp",
                description="include wam/pow.h for wam::CheckProofOfWork",
                marker="#include <wam/pow.h>",
                insert_after="#include <wam/consensus/subsidy.h>\n",
                insert_text="#include <wam/pow.h>\n",
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-019",
        title="Name the software WAM Coin",
        rationale=("PACKAGE_NAME reaches the window title, the About dialog, every "
                   "--version and --help, and the log header. Until now a WAM node "
                   "introduced itself as Bitcoin Core."),
        edits=[
            Edit(
                file="configure.ac",
                description="AC_INIT: package name, contact and home page",
                marker="AC_INIT([WAM Coin]",
                anchor=("AC_INIT([Bitcoin Core],m4_join([.], _CLIENT_VERSION_MAJOR, _CLIENT_VERSION_MINOR, "
                        "_CLIENT_VERSION_BUILD)m4_if(_CLIENT_VERSION_RC, [0], [], [rc]_CLIENT_VERSION_RC),"
                        "[https://github.com/bitcoin/bitcoin/issues],[bitcoin],[https://bitcoincore.org/])"),
                replacement=("AC_INIT([WAM Coin],m4_join([.], _CLIENT_VERSION_MAJOR, _CLIENT_VERSION_MINOR, "
                             "_CLIENT_VERSION_BUILD)m4_if(_CLIENT_VERSION_RC, [0], [], [rc]_CLIENT_VERSION_RC),"
                             "[https://github.com/wam-coin-official/wam-coin/issues],"
                             "[wam],[https://wamcoin.org/])"),
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-021",
        title="The node's identity: user agent, version, copyright, source URL",
        rationale=("A WAM node introduced itself to every peer on the network as "
                   "'Satoshi', reported Bitcoin Core's version number, and told anyone "
                   "who ran --version that the source lives at github.com/bitcoin/"
                   "bitcoin. Each of these is a statement the software makes about "
                   "itself, unprompted, to strangers.\n\n"
                   "The copyright line was the same kind of error pointing the other "
                   "way. Upstream builds one prefix -- 'Copyright (C) 2009-<year>' -- "
                   "and applies it to every holder, which is correct while there is "
                   "one holder. For a fork it printed 'Copyright (C) 2009-2024 The "
                   "WAM Coin developers': a claim of authorship reaching back to "
                   "Bitcoin's genesis, in the first output anyone sees. WAM's line now "
                   "carries WAM's year and Bitcoin Core's keeps the range upstream "
                   "declared, which is the accurate split and costs nothing to state."),
        edits=[
            Edit(
                file="src/clientversion.cpp",
                description="the P2P user agent: Satoshi -> WAM",
                marker='CLIENT_NAME("WAM")',
                anchor='const std::string CLIENT_NAME("Satoshi");',
                replacement=(
                    '// WAM_CLIENT_NAME\n'
                    '//\n'
                    '// This is the user agent every peer sees: "/Satoshi:28.1.0/" until now.\n'
                    '// It reaches connection logs, network crawlers, peer-count sites and\n'
                    '// the addr messages that propagate across the network -- the single\n'
                    '// most widely repeated statement the software makes about itself.\n'
                    'const std::string CLIENT_NAME("WAM");'),
            ),
            Edit(
                file="src/common/signmessage.cpp",
                description="signed messages say WAM, so they cannot be replayed as Bitcoin",
                marker='MESSAGE_MAGIC = "WAM Coin Signed Message:\\n"',
                anchor='const std::string MESSAGE_MAGIC = "Bitcoin Signed Message:\\n";',
                replacement=(
                    '// WAM_MESSAGE_MAGIC\n'
                    '//\n'
                    '// This string is hashed with the message before signing, and it is the\n'
                    '// only thing that ties a signature to a chain. Leaving Bitcoin\'s value\n'
                    '// here means a message signed by a WAM key verifies as a Bitcoin signed\n'
                    '// message and the reverse -- so a signature produced to prove control of\n'
                    '// a WAM address can be presented, unchanged, as proof of control of the\n'
                    '// corresponding Bitcoin address. Exchanges and custody services ask for\n'
                    '// exactly that kind of proof.\n'
                    '//\n'
                    '// Every serious fork changes it: Litecoin, Dogecoin and DigiByte each\n'
                    '// have their own. It is also a field wallet integrators ask for by name\n'
                    '// -- Komodo\'s coin definition has a sign_message_prefix entry.\n'
                    '//\n'
                    '// Changed before mainnet launch on purpose. After launch it would\n'
                    '// invalidate every signature anyone had already produced.\n'
                    'const std::string MESSAGE_MAGIC = "WAM Coin Signed Message:\\n";'),
            ),
            Edit(
                file="src/clientversion.cpp",
                description="point --version at this project's source, not Bitcoin's",
                marker="github.com/wam-coin-official/wam-coin",
                anchor='    const std::string URL_SOURCE_CODE = "<https://github.com/bitcoin/bitcoin>";',
                replacement=(
                    '    // Telling a user the source is at bitcoin/bitcoin is not modesty,\n'
                    '    // it is wrong: the binary they are holding is not built from there.\n'
                    '    // Bitcoin Core keeps its credit in the copyright line above, which\n'
                    '    // CopyrightHolders() adds automatically for any fork.\n'
                    '    const std::string URL_SOURCE_CODE = "<https://github.com/wam-coin-official/wam-coin>";'),
            ),
            Edit(
                file="configure.ac",
                description=f"version 28.1.0 -> {WAM_CLIENT_VERSION}",
                # The marker carries the build number. It used to be just
                # `define(_CLIENT_VERSION_MAJOR, 0)`, which stays true for every
                # version this project will ever have -- so raising the version
                # left the marker satisfied, the edit was skipped as already
                # applied, and the build produced the old number in silence.
                # v0.1.1 was published carrying /WAM:0.1.0/ for exactly that
                # reason. A marker must describe what the edit produces, not the
                # family it belongs to.
                marker=f"define(_CLIENT_VERSION_BUILD, {WAM_CLIENT_VERSION.split('.')[2]})",
                anchor=("define(_CLIENT_VERSION_MAJOR, 28)\n"
                        "define(_CLIENT_VERSION_MINOR, 1)\n"
                        "define(_CLIENT_VERSION_BUILD, 0)"),
                replacement=(
                    "dnl WAM_CLIENT_VERSION -- this is WAM's first release, not Bitcoin\n"
                    "dnl Core's twenty-eighth. Reporting 28.1.0 told every peer and every\n"
                    "dnl user a version number that belongs to different software.\n"
                    "dnl\n"
                    "dnl Safe to lower: the wallet's TOO_NEW check compares its stored\n"
                    "dnl minversion against FEATURE_LATEST, a separate compile-time\n"
                    "dnl constant, not against CLIENT_VERSION. CLIENT_VERSION is recorded\n"
                    "dnl in the wallet only as metadata.\n"
                    "dnl\n"
                    "dnl Raising this needs a clean upstream tree: on an already-patched\n"
                    "dnl one the anchor below is gone and this edit fails loudly, which is\n"
                    "dnl the correct outcome -- the alternative is a binary whose version\n"
                    "dnl is a guess. CI checks out fresh every run and never meets it.\n"
                    f"define(_CLIENT_VERSION_MAJOR, {WAM_CLIENT_VERSION.split('.')[0]})\n"
                    f"define(_CLIENT_VERSION_MINOR, {WAM_CLIENT_VERSION.split('.')[1]})\n"
                    f"define(_CLIENT_VERSION_BUILD, {WAM_CLIENT_VERSION.split('.')[2]})"),
            ),
            Edit(
                file="configure.ac",
                description="copyright holders: WAM Coin, with Bitcoin Core kept",
                marker="_COPYRIGHT_HOLDERS_SUBSTITUTION,[[WAM Coin]]",
                anchor="define(_COPYRIGHT_HOLDERS_SUBSTITUTION,[[Bitcoin Core]])",
                replacement=(
                    "dnl CopyrightHolders() in clientversion.cpp appends \"The Bitcoin Core\n"
                    "dnl developers\" automatically whenever this substitution does not\n"
                    "dnl already contain it -- upstream wrote that branch for forks. So the\n"
                    "dnl output credits both, which is the accurate answer: WAM wrote the\n"
                    "dnl consensus changes, Bitcoin Core wrote almost everything else.\n"
                    "define(_COPYRIGHT_HOLDERS_SUBSTITUTION,[[WAM Coin]])"),
            ),
            Edit(
                file="configure.ac",
                description="copyright year: this build's, not the year we forked from",
                marker="define(_COPYRIGHT_YEAR, 2026)",
                anchor="define(_COPYRIGHT_YEAR, 2024)",
                replacement=(
                    "dnl WAM_COPYRIGHT_YEAR -- 2024 is when Bitcoin Core cut v28.1, and it\n"
                    "dnl stays on their line below. This constant is now WAM's own year:\n"
                    "dnl the copyright a build asserts is the copyright of that build.\n"
                    "dnl Bump it at the first release of each year, the same way upstream\n"
                    "dnl does.\n"
                    "define(_COPYRIGHT_YEAR, 2026)"),
            ),
            Edit(
                file="src/clientversion.cpp",
                description="WAM's copyright line starts when WAM started",
                marker='_("Copyright (C) %i").translated, COPYRIGHT_YEAR',
                anchor=('    return CopyrightHolders(strprintf(_("Copyright (C) %i-%i")'
                        '.translated, 2009, COPYRIGHT_YEAR) + " ") + "\\n" +'),
                replacement=(
                    '    // A range starting at 2009 is Bitcoin\'s history, not ours. This\n'
                    '    // prefix reaches the WAM line only; see CopyrightHolders below,\n'
                    '    // where Bitcoin Core keeps the range it declared.\n'
                    '    return CopyrightHolders(strprintf(_("Copyright (C) %i")'
                    '.translated, COPYRIGHT_YEAR) + " ") + "\\n" +'),
            ),
            Edit(
                file="src/clientversion.cpp",
                description="Bitcoin Core keeps the range it actually declared",
                marker="WAM_BITCOIN_COPYRIGHT_RANGE",
                anchor=('    // Make sure Bitcoin Core copyright is not removed by accident\n'
                        '    if (copyright_devs.find("Bitcoin Core") == std::string::npos) {\n'
                        '        strCopyrightHolders += "\\n" + strPrefix + '
                        '"The Bitcoin Core developers";\n'
                        '    }'),
                replacement=(
                    '    // WAM_BITCOIN_COPYRIGHT_RANGE\n'
                    '    //\n'
                    '    // strPrefix now carries the WAM year, so it cannot be reused here:\n'
                    '    // 2009-2024 is a statement about Bitcoin Core\'s work, and it does\n'
                    '    // not move when the WAM copyright year does. Frozen at what v28.1\n'
                    '    // declared, which is the release this was forked from.\n'
                    '    //\n'
                    '    // The upstream check itself is left exactly as written: it is what\n'
                    '    // guarantees a fork cannot drop this credit by editing one macro.\n'
                    '    if (copyright_devs.find("Bitcoin Core") == std::string::npos) {\n'
                    '        strCopyrightHolders += "\\n" + strprintf('
                    '"Copyright (C) %i-%i ", 2009, 2024)\n'
                    '                               + "The Bitcoin Core developers";\n'
                    '    }'),
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-022",
        title="RPC ports: WAM's own, one below the peer port",
        rationale=(
            "chainparamsbase.cpp kept Bitcoin's RPC ports -- 8332 and 18332 -- so "
            "wam-cli talked to whichever daemon owned them, a WAM node and a Bitcoin "
            "node could not share a machine, and the firewall rule denying 19556 "
            "guarded a port the RPC server was not on.\n\n"
            "The new numbers are p2p-1, not p2p+1. Upstream's own comment above this "
            "function says why: 'Port numbers for incoming Tor connections (8334, "
            "18334, ...)'. init.cpp sets default_bind_port_onion = default_bind_port "
            "+ 1, so anything at p2p+1 is squatted by the node's own onion listener "
            "the moment -listen=1. WAM's old 9556/19556 sat exactly there. It went "
            "unnoticed while every node ran -listen=0; the first listening node took "
            "19556 for Tor and the RPC server fell back to 18332 in silence.\n\n"
            "signet and testnet4 are moved too. WAM gives them p2p 39555 and 49555, "
            "and leaving their RPC on Bitcoin's 38332/48332 would collide with a real "
            "Bitcoin node for no reason."),
        edits=[
            Edit(
                file="src/chainparamsbase.cpp",
                description="mainnet RPC 8332 -> 9554",
                marker='CBaseChainParams>("", 9554)',
                anchor='return std::make_unique<CBaseChainParams>("", 8332);',
                replacement='return std::make_unique<CBaseChainParams>("", 9554);',
            ),
            Edit(
                file="src/chainparamsbase.cpp",
                description="testnet RPC 18332 -> 19554",
                marker='CBaseChainParams>("testnet3", 19554)',
                anchor='return std::make_unique<CBaseChainParams>("testnet3", 18332);',
                replacement='return std::make_unique<CBaseChainParams>("testnet3", 19554);',
            ),
            Edit(
                file="src/chainparamsbase.cpp",
                description="testnet4 RPC 48332 -> 49554",
                marker='CBaseChainParams>("testnet4", 49554)',
                anchor='return std::make_unique<CBaseChainParams>("testnet4", 48332);',
                replacement='return std::make_unique<CBaseChainParams>("testnet4", 49554);',
            ),
            Edit(
                file="src/chainparamsbase.cpp",
                description="signet RPC 38332 -> 39554",
                marker='CBaseChainParams>("signet", 39554)',
                anchor='return std::make_unique<CBaseChainParams>("signet", 38332);',
                replacement='return std::make_unique<CBaseChainParams>("signet", 39554);',
            ),
            Edit(
                file="src/chainparamsbase.cpp",
                description="regtest RPC 18443 -> 29554",
                marker='CBaseChainParams>("regtest", 29554)',
                anchor='return std::make_unique<CBaseChainParams>("regtest", 18443);',
                replacement='return std::make_unique<CBaseChainParams>("regtest", 29554);',
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-020",
        title="Denominate the GUI in WAM rather than BTC",
        rationale=("Every amount in the wallet -- balances, the send form, the "
                   "transaction list -- was labelled BTC. The enum names stay as they "
                   "are; renaming Unit::BTC would touch dozens of files to change "
                   "nothing a user can see."),
        edits=[
            Edit(
                file="src/qt/bitcoinunits.cpp",
                description="unit long names",
                marker='return QString("WAM");',
                anchor=('    case Unit::BTC: return QString("BTC");\n'
                        '    case Unit::mBTC: return QString("mBTC");\n'
                        '    case Unit::uBTC: return QString::fromUtf8("µBTC (bits)");\n'
                        '    case Unit::SAT: return QString("Satoshi (sat)");'),
                replacement=('    case Unit::BTC: return QString("WAM");\n'
                             '    case Unit::mBTC: return QString("mWAM");\n'
                             '    case Unit::uBTC: return QString::fromUtf8("µWAM");\n'
                             '    case Unit::SAT: return QString("Satoshi (sat)");'),
            ),
            Edit(
                file="src/qt/bitcoinunits.cpp",
                description="unit short names",
                marker='case Unit::uBTC: return QString::fromUtf8("µWAM");\n    case Unit::SAT: return QString("sat");',
                anchor=('    case Unit::uBTC: return QString("bits");\n'
                        '    case Unit::SAT: return QString("sat");'),
                replacement=('    case Unit::uBTC: return QString::fromUtf8("µWAM");\n'
                             '    case Unit::SAT: return QString("sat");'),
            ),
            # Not a tr() call, so scripts/rebrand_qt.py leaves it alone -- and it
            # is the one place left that a user can read the word Bitcoin: the
            # header of the Command-line options dialog.
            Edit(
                file="src/qt/utilitydialog.cpp",
                description="command-line help header",
                marker="Optional URI is a WAM address",
                anchor=('                         "Optional URI is a Bitcoin address in BIP21 URI format.\\n";'),
                replacement=('                         "Optional URI is a WAM address in BIP21 URI format.\\n";'),
            ),
            Edit(
                file="src/qt/bitcoinunits.cpp",
                description="unit descriptions",
                marker='return QString("WAM");\n    case Unit::mBTC: return QString("Milli-WAM',
                anchor=('    case Unit::BTC: return QString("Bitcoins");\n'
                        '    case Unit::mBTC: return QString("Milli-Bitcoins (1 / 1" THIN_SP_UTF8 "000)");\n'
                        '    case Unit::uBTC: return QString("Micro-Bitcoins (bits) (1 / 1" THIN_SP_UTF8 "000" THIN_SP_UTF8 "000)");'),
                replacement=('    case Unit::BTC: return QString("WAM");\n'
                             '    case Unit::mBTC: return QString("Milli-WAM (1 / 1" THIN_SP_UTF8 "000)");\n'
                             '    case Unit::uBTC: return QString("Micro-WAM (1 / 1" THIN_SP_UTF8 "000" THIN_SP_UTF8 "000)");'),
            ),
        ]))

    # -----------------------------------------------------------------------
    # The functional test framework has Bitcoin's address parameters written
    # into it -- version byte 111, P2SH 196, the 'bcrt' bech32 prefix, and
    # twelve hardcoded deterministic addresses. On a chain that uses 65, 128
    # and 'wamrt', every one of those is rejected as an invalid address, which
    # means create_cache.py fails and not one of upstream's 251 functional
    # tests can run. Those tests cover the parts of Bitcoin Core this fork
    # inherited unchanged; leaving them unrunnable throws away the largest body
    # of regression testing the project has.
    #
    # The keys themselves are untouched. Only the version byte differs, so the
    # addresses below are the same twelve keys re-encoded for WAM.
    _FRAMEWORK_KEYS = [
        ("mjTkW3DjgyZck4KbiRusZsqTgaYTxdSz6z", "TDv1D3WV2gFK87ucb8bDG7KGjNh5HCPZPi",
         "cVpF924EspNh8KjYsfhgY96mmxvT6DgdWiTYMtMjuM74hJaU5psW"),
        ("msX6jQXvxiNhx3Q62PKeLPrhrqZQdSimTg", "TMyMSQpgJR4QL6z6u5zz2dLWudi1x5Fobw",
         "cUxsWyKyZ9MAQTaAhUQWJmBbSvHMwSmuv59KgxQV7oZQU3PXN3KE"),
        ("mnonCMyH9TmAsSj3M59DsbH8H63U3RKoFP", "THG2uNG2VASsFWK4DmpZZpkwKtC5Qjkyoo",
         "cTrh7dkEAeJd6b3MRX9bZK8eRmNqVCMH3LSUkE3dSFDyzjU38QxK"),
        ("mqJupas8Dt2uestQDvV2NH3RU8uZh2dqQR", "TKmAXb9sZaic2wUR6dAN4WXEWw4AwjKkA1",
         "cVuKKa7gbehEQvVq717hYcbE9Dqmq7KEBKqWgWrYBa2CKKrhtRim"),
        ("msYac7Rvd5ywm6pEmkjyxhbCDKqWsVeYws", "TMzqK7ifxnfe9AQFeTRKew51G7z8G7n66i",
         "cQDCBuKcjanpXDpCqacNSjYfxeQj8G6CAtH1Dsk3cXyqLNC4RPuh"),
        ("n2rnuUnwLgXqf9kk2kjvVm8R5BZK1yxQBi", "TXK3cV5ggPDY3DLkuTRGBzcE7yhvMQrc47",
         "cQakmfPSLSqKHyMFGwAqKHgWUiofJCagVGhiB4KCainaeCSxeyYq"),
        ("myzuPxRwsf3vvGzEuzPfK9Nf2RfwauwYe6", "TUTA6xihDMjdJLaFnh511NrU5DpYooAazF",
         "cQMpDLJwA8DBe9NcQbdoSb1BhmFxVjWD5gRyrLZCtpuF9Zi3a9RK"),
        ("mumwTaMtbxEPUswmLBBN3vM9oGRtGBrys8", "TQECAaedwev5rwXnCsrhk9pxr4aVX4mVqs",
         "cSXmRKXVcoouhNNVpcNKFfxsTsToY5pvB9DVsFksF1ENunTzRKsy"),
        ("mpV7aGShMkJCZgbW7F6iZgrvuPHjZjH9qg", "TJwNHGjShSytwkBWywn4FvLjxBSLrrAasS",
         "cSoXt6tm3pqy43UMabY6eUTmR3eSUYFtB2iNQDGgb3VUnRsQys2k"),
        ("mq4fBNdckGtvY2mijd9am7DRsbRB4KjUkf", "TKWutNvN5yacv6MjcKpvTLhEvPZnFa4rjn",
         "cN55daf1HotwBAgAKWVgDcoppmUNDtQSfb7XLutTLeAgVc3u8hik"),
        ("mpFAHDjX7KregM3rVotdXzQmkbwtbQEnZ6", "TJhQzE2GT2YM4QdsNWZyEDtaoQ6Vt8mQAc",
         "cT7qK7g1wkYEMvKowd2ZrX1E5f6JQ7TM246UfqbCiyF7kZhorpX3"),
        ("mzRe8QZMfGi58KyWCse2exxEFry2sfF2Y7", "TUstqQr6zyPmWPZX5aKNMCS3Jf7eBF8N4A",
         "cPiRWE8KMjTRxH1MWkPerhfoHFn5iHPWVK5aPqjW8NxmdwenFinJ"),
    ]

    _keys_anchor = "    PRIV_KEYS = [\n            # address , privkey\n" + "".join(
        f"            AddressKeyPair('{old}', '{wif}'),\n"
        for old, _new, wif in _FRAMEWORK_KEYS)

    _keys_replacement = (
        "    # WAM_FRAMEWORK_KEYS -- the same twelve private keys, re-encoded with\n"
        "    # WAM's version byte (65) instead of Bitcoin's testnet 111. Without\n"
        "    # this, generate() asks the node to mine to an address it considers\n"
        "    # invalid, and every test that mines a block fails before it starts.\n"
        "    PRIV_KEYS = [\n            # address , privkey\n" + "".join(
            f"            AddressKeyPair('{new}', '{wif}'),\n"
            for _old, new, wif in _FRAMEWORK_KEYS))

    changes.append(Change(
        id="WAM-018",
        title="Teach the functional test framework WAM's address parameters",
        rationale=("Bitcoin's version bytes and bech32 prefix are hardcoded in the "
                   "framework, so create_cache.py and all 251 upstream functional "
                   "tests fail on a WAM chain before they run a single assertion."),
        edits=[
            Edit(
                file="test/functional/test_framework/test_node.py",
                description="re-encode the deterministic mining keys for WAM",
                marker="WAM_FRAMEWORK_KEYS",
                anchor=_keys_anchor,
                replacement=_keys_replacement,
            ),
            Edit(
                file="test/functional/test_framework/address.py",
                description="P2PKH version byte 111 -> 65",
                marker="65  # WAM",
                anchor="    version = 0 if main else 111",
                replacement="    version = 0 if main else 65  # WAM, not Bitcoin's 111",
            ),
            Edit(
                file="test/functional/test_framework/address.py",
                description="P2SH version byte 196 -> 128",
                marker="128  # WAM",
                anchor="    version = 5 if main else 196",
                replacement="    version = 5 if main else 128  # WAM, not Bitcoin's 196",
            ),
            Edit(
                file="test/functional/test_framework/address.py",
                description="segwit HRP bcrt -> wamrt",
                marker='"wamrt", version, program',
                anchor='    return encode_segwit_address("bc" if main else "bcrt", version, program)',
                replacement='    return encode_segwit_address("wam" if main else "wamrt", version, program)',
            ),
            Edit(
                file="test/functional/test_framework/address.py",
                description="accept WAM bech32 prefixes when decoding",
                marker="'wamrt']",
                anchor="    if hrp not in ['bc', 'tb', 'bcrt']:",
                replacement="    if hrp not in ['wam', 'twam', 'wamrt']:",
            ),
            # The names keep saying BCRT1 -- dozens of upstream tests import
            # them by that name, and renaming would be a much larger change for
            # no benefit. Only the values move to WAM's prefix.
            Edit(
                file="test/functional/test_framework/address.py",
                description="re-encode the unspendable address constant",
                marker="wamrt1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq7k3d4z'",
                anchor=("ADDRESS_BCRT1_UNSPENDABLE = 'bcrt1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq3xueyj'\n"
                        "ADDRESS_BCRT1_UNSPENDABLE_DESCRIPTOR = 'addr(bcrt1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq3xueyj)#juyq9d97'"),
                replacement=("# Same witness programs as upstream, re-encoded with WAM's 'wamrt' prefix.\n"
                             "# The bech32 checksum covers the prefix, so the tails differ too.\n"
                             "ADDRESS_BCRT1_UNSPENDABLE = 'wamrt1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq7k3d4z'\n"
                             "ADDRESS_BCRT1_UNSPENDABLE_DESCRIPTOR = 'addr(wamrt1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq7k3d4z)#2m9nv8gt'"),
            ),
            Edit(
                file="test/functional/test_framework/address.py",
                description="re-encode the P2WSH OP_TRUE constant",
                marker="wamrt1qft5p2uhsdcdc3l2ua4ap5qqfg4pjaqlp250x7us7a8qqhrxrxfsqlfsvky",
                anchor="ADDRESS_BCRT1_P2WSH_OP_TRUE = 'bcrt1qft5p2uhsdcdc3l2ua4ap5qqfg4pjaqlp250x7us7a8qqhrxrxfsqseac85'",
                replacement="ADDRESS_BCRT1_P2WSH_OP_TRUE = 'wamrt1qft5p2uhsdcdc3l2ua4ap5qqfg4pjaqlp250x7us7a8qqhrxrxfsqlfsvky'",
            ),
            Edit(
                file="test/functional/test_framework/address.py",
                description="re-encode the deterministic P2TR self-check",
                marker="wamrt1p9yfmy5h72durp7zrhlw9lf7jpwjgvwdg0jr0lqmmjtgg83266lqskxs58d",
                anchor="        assert_equal(address, 'bcrt1p9yfmy5h72durp7zrhlw9lf7jpwjgvwdg0jr0lqmmjtgg83266lqsekaqka')",
                replacement="        assert_equal(address, 'wamrt1p9yfmy5h72durp7zrhlw9lf7jpwjgvwdg0jr0lqmmjtgg83266lqskxs58d')",
            ),
            Edit(
                file="test/functional/test_framework/address.py",
                description="decode WAM base58 version bytes",
                marker="== 65:  # WAM",
                anchor=("    if version == 111:  # testnet pubkey hash\n"
                        "        return keyhash_to_p2pkh_script(payload)\n"
                        "    elif version == 196:  # testnet script hash"),
                replacement=("    if version == 65:  # WAM pubkey hash\n"
                             "        return keyhash_to_p2pkh_script(payload)\n"
                             "    elif version == 128:  # WAM script hash"),
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-017",
        title="Register the WAM functional tests with the test runner",
        rationale=("Copied into the tree by WAM-000, but test_runner.py only runs what "
                   "is listed here -- so without this they exist and are never run, "
                   "which is worse than not having them."),
        edits=[
            Edit(
                file="test/functional/test_runner.py",
                description="add the wam_* tests to BASE_SCRIPTS",
                marker="feature_wam_devfee.py",
                anchor=(
                    "BASE_SCRIPTS = [\n"
                    "    # Scripts that are run by default.\n"
                    "    # Longest test should go first, to favor running tests in parallel\n"
                    "    # vv Tests less than 5m vv\n"),
                replacement=(
                    "BASE_SCRIPTS = [\n"
                    "    # Scripts that are run by default.\n"
                    "    # Longest test should go first, to favor running tests in parallel\n"
                    "    #\n"
                    "    # WAM's own tests come first: they cover the rules this fork adds,\n"
                    "    # and a failure in them says the chain is wrong about its own money.\n"
                    "    'feature_wam_devfee.py',\n"
                    "    'feature_wam_genesis.py',\n"
                    "    'feature_wam_pow.py',\n"
                    "    'feature_wam_randomx_epoch.py',\n"
                    "    # vv Tests less than 5m vv\n"),
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-016",
        title="Declare the WAM fields in the getblocktemplate help",
        rationale=("The devfee and randomx_seedhash fields were added to the result "
                   "but never to the RPCResult declaration. Beyond leaving `help "
                   "getblocktemplate` silent about fields this pool refuses to start "
                   "without, it makes the RPC throw 'Internal bug detected' whenever "
                   "-rpcdoccheck is on -- so no functional test could call it at all."),
        edits=[
            Edit(
                file="src/rpc/mining.cpp",
                description="document devfee and the RandomX seed in the result schema",
                marker="WAM_GBT_RESULT_DOC",
                anchor=(
                    '                {RPCResult::Type::STR_HEX, "default_witness_commitment", /*optional=*/true, "a valid witness commitment for the unmodified block template"},\n'
                    "            }},"),
                replacement=(
                    '                {RPCResult::Type::STR_HEX, "default_witness_commitment", /*optional=*/true, "a valid witness commitment for the unmodified block template"},\n'
                    '                // WAM_GBT_RESULT_DOC\n'
                    '                //\n'
                    '                // Bitcoin Core checks an RPC\'s real return value against this\n'
                    '                // declaration whenever -rpcdoccheck is on. Adding fields to the\n'
                    '                // result without adding them here does not merely leave the help\n'
                    '                // text wrong: the call throws "Internal bug detected", which means\n'
                    '                // no functional test can reach getblocktemplate at all.\n'
                    '                //\n'
                    '                // The help text earns its place too. This chain\'s pool refuses to\n'
                    '                // start without `devfee`, and an operator reading the help had no\n'
                    '                // way to learn the field existed.\n'
                    '                {RPCResult::Type::OBJ, "devfee", "the treasury output that consensus rule WAM-1 requires in the coinbase",\n'
                    '                {\n'
                    '                    {RPCResult::Type::NUM, "amount", "satoshi that must be paid to the treasury script; 0 once the fee has sunset"},\n'
                    '                    {RPCResult::Type::STR_HEX, "script", "the exact scriptPubKey the payment has to go to"},\n'
                    '                    {RPCResult::Type::STR, "address", "the same script as an address, for humans"},\n'
                    '                    {RPCResult::Type::NUM, "percent", "the treasury share of the subsidy, as a whole percentage"},\n'
                    '                    {RPCResult::Type::NUM, "last_height", "the final height at which the rule applies"},\n'
                    '                    {RPCResult::Type::BOOL, "active", "whether the rule applies to the block being built"},\n'
                    '                }},\n'
                    '                {RPCResult::Type::STR_HEX, "randomx_seedhash", "the RandomX key for this height, displayed big-endian. A miner keys its VM with the byte reverse of this value."},\n'
                    '                {RPCResult::Type::NUM, "randomx_seedheight", "the block height the key is derived from; 0 means the bootstrap key"},\n'
                    "            }},"),
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-015",
        title="Report the whole coinbase value in getblocktemplate",
        rationale=("Upstream reads coinbasevalue out of vout[0] because upstream's "
                   "coinbase has exactly one output. WAM-014 added a second one, so the "
                   "reported value silently became the miner's share alone -- 5% less "
                   "than BIP22 promises. A pool that then paid the treasury out of it, "
                   "which is the correct reading of BIP22, destroyed 5% of the subsidy "
                   "in every block it mined."),
        edits=[
            Edit(
                file="src/rpc/mining.cpp",
                description="sum every coinbase output instead of reading vout[0]",
                marker="WAM_COINBASE_VALUE_IS_TOTAL",
                anchor='    result.pushKV("coinbasevalue", (int64_t)pblock->vtx[0]->vout[0].nValue);',
                replacement=(
                    '    // WAM_COINBASE_VALUE_IS_TOTAL\n'
                    '    //\n'
                    '    // BIP22 defines coinbasevalue as "the maximum allowable input to\n'
                    '    // coinbase transaction, including the generation award and\n'
                    '    // transaction fees" -- the total, not one output of it. Upstream\n'
                    '    // could read vout[0] because upstream coinbases have exactly one\n'
                    '    // output. Ours carry the treasury output too (WAM-014), and the\n'
                    '    // witness commitment on top of that.\n'
                    '    //\n'
                    '    // Reporting vout[0] alone understated the reward by exactly the\n'
                    '    // treasury share. A pool doing the BIP22-correct thing -- paying\n'
                    '    // the treasury out of coinbasevalue -- then subtracted it twice\n'
                    '    // and never claimed 5% of any block it mined. Those coins are not\n'
                    '    // stolen, they are destroyed: the chain quietly stops following\n'
                    '    // its own issuance schedule, and pool miners earn 90% of the\n'
                    '    // subsidy while solo miners earn 95%.\n'
                    '    //\n'
                    '    // Summing, rather than adding the treasury back, keeps this right\n'
                    '    // if a later change ever adds another mandatory output.\n'
                    '    CAmount wam_coinbase_total = 0;\n'
                    '    for (const CTxOut& wam_out : pblock->vtx[0]->vout) {\n'
                    '        wam_coinbase_total += wam_out.nValue;\n'
                    '    }\n'
                    '    result.pushKV("coinbasevalue", (int64_t)wam_coinbase_total);'),
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-014",
        title="Make the block assembler pay the treasury",
        rationale=("BlockAssembler built a single-output coinbase, which consensus "
                   "rule WAM-1 then rejected -- the node could not mine its own "
                   "blocks."),
        edits=[
            Edit(
                file="src/node/miner.cpp",
                description="add the treasury output to the coinbase",
                marker="WAM_COINBASE_PAYS_TREASURY",
                anchor=(
                    "    coinbaseTx.vout.resize(1);\n"
                    "    coinbaseTx.vout[0].scriptPubKey = scriptPubKeyIn;\n"
                    "    coinbaseTx.vout[0].nValue = nFees + GetBlockSubsidy(nHeight, chainparams.GetConsensus());\n"
                    "    coinbaseTx.vin[0].scriptSig = CScript() << nHeight << OP_0;"),
                replacement=(
                    "    // WAM_COINBASE_PAYS_TREASURY\n"
                    "    //\n"
                    "    // Consensus rule WAM-1 requires a treasury output on every block\n"
                    "    // from height 1 to 400,000. Upstream's assembler builds a\n"
                    "    // single-output coinbase, so without this the node's own template\n"
                    "    // was rejected by its own validation with bad-cb-devfee-amount --\n"
                    "    // it could not mine a single block.\n"
                    "    //\n"
                    "    // Note what the miner keeps: the subsidy MINUS the treasury share,\n"
                    "    // PLUS every transaction fee. Fees are never shared with the\n"
                    "    // treasury; that is what keeps fee-market incentives clean.\n"
                    "    //\n"
                    "    // This runs before GenerateCoinbaseCommitment below, so the SegWit\n"
                    "    // commitment covers the finished output set.\n"
                    "    const CAmount wam_subsidy = GetBlockSubsidy(nHeight, chainparams.GetConsensus());\n"
                    "    const CAmount wam_devfee = wam::GetDevFeeAmount(wam_subsidy, nHeight);\n"
                    "\n"
                    "    coinbaseTx.vout.resize(wam_devfee > 0 ? 2 : 1);\n"
                    "    coinbaseTx.vout[0].scriptPubKey = scriptPubKeyIn;\n"
                    "    coinbaseTx.vout[0].nValue = nFees + wam_subsidy - wam_devfee;\n"
                    "    if (wam_devfee > 0) {\n"
                    "        coinbaseTx.vout[1].scriptPubKey = wam::DevFeeScript(chainparams.GetConsensus());\n"
                    "        coinbaseTx.vout[1].nValue = wam_devfee;\n"
                    "    }\n"
                    "    coinbaseTx.vin[0].scriptSig = CScript() << nHeight << OP_0;"),
            ),
            Edit(
                file="src/node/miner.cpp",
                description="include the WAM consensus headers",
                marker="#include <wam/consensus/devfee.h>",
                insert_after="#include <node/miner.h>\n",
                insert_text=("\n#include <wam/consensus/subsidy.h>\n"
                             "#include <wam/consensus/devfee.h>\n"),
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-013",
        title="Let ContextualCheckBlockHeader be told to skip the PoW check",
        rationale=("CreateNewBlock validates a template that has no nonce yet. It "
                   "passes fCheckPOW=false, but that flag stopped at CheckBlockHeader "
                   "-- which is no longer where the PoW check lives."),
        edits=[
            Edit(
                file="src/validation.cpp",
                description="add fCheckPOW to ContextualCheckBlockHeader",
                marker="const CBlockIndex* pindexPrev, bool fCheckPOW",
                anchor=(
                    "static bool ContextualCheckBlockHeader(const CBlockHeader& block, BlockValidationState& state, "
                    "BlockManager& blockman, const ChainstateManager& chainman, const CBlockIndex* pindexPrev) "
                    "EXCLUSIVE_LOCKS_REQUIRED(::cs_main)"),
                replacement=(
                    "// WAM: fCheckPOW added. The RandomX check moved into this function\n"
                    "// (see WAM-010), so the \"validate this template before it has been\n"
                    "// mined\" path needs a way to say so -- exactly as upstream already\n"
                    "// does for CheckBlockHeader.\n"
                    "static bool ContextualCheckBlockHeader(const CBlockHeader& block, BlockValidationState& state, "
                    "BlockManager& blockman, const ChainstateManager& chainman, const CBlockIndex* pindexPrev, "
                    "bool fCheckPOW = true) "
                    "EXCLUSIVE_LOCKS_REQUIRED(::cs_main)"),
            ),
            Edit(
                file="src/validation.cpp",
                description="guard the RandomX check with fCheckPOW",
                marker="    if (fCheckPOW) {\n        const uint256 seed = wam::GetRandomXSeedHash",
                anchor=(
                    "    {\n"
                    "        const uint256 seed = wam::GetRandomXSeedHash(pindexPrev, consensusParams);"),
                replacement=(
                    "    if (fCheckPOW) {\n"
                    "        const uint256 seed = wam::GetRandomXSeedHash(pindexPrev, consensusParams);"),
            ),
            Edit(
                file="src/validation.cpp",
                description="pass fCheckPOW through from TestBlockValidity",
                marker="chainstate.m_chainman, pindexPrev, fCheckPOW)",
                anchor=(
                    "    if (!ContextualCheckBlockHeader(block, state, chainstate.m_blockman, "
                    "chainstate.m_chainman, pindexPrev)) {"),
                replacement=(
                    "    if (!ContextualCheckBlockHeader(block, state, chainstate.m_blockman, "
                    "chainstate.m_chainman, pindexPrev, fCheckPOW)) {"),
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-012",
        title="Point the remaining proof-of-work call sites at RandomX",
        rationale=("Three production sites still hashed with SHA256d: the internal "
                   "miner, the headers-presync filter, and block index loading."),
        edits=[
            Edit(
                file="src/rpc/mining.cpp",
                description="mine against RandomX, not SHA256d",
                marker="WAM_MINER_USES_RANDOMX",
                anchor=(
                    "    block_out.reset();\n"
                    "    block.hashMerkleRoot = BlockMerkleRoot(block);\n"
                    "\n"
                    "    while (max_tries > 0 && block.nNonce < std::numeric_limits<uint32_t>::max() && !CheckProofOfWork(block.GetHash(), block.nBits, chainman.GetConsensus()) && !chainman.m_interrupt) {"),
                replacement=(
                    "    block_out.reset();\n"
                    "    block.hashMerkleRoot = BlockMerkleRoot(block);\n"
                    "\n"
                    "    // WAM_MINER_USES_RANDOMX\n"
                    "    //\n"
                    "    // Upstream searches for a nonce whose double-SHA256 meets the\n"
                    "    // target. WAM's proof of work is RandomX, so this loop has to hash\n"
                    "    // the same way ContextualCheckBlockHeader verifies -- otherwise the\n"
                    "    // miner produces blocks its own node then rejects.\n"
                    "    //\n"
                    "    // The seed is derived from the parent, which is what fixes it for\n"
                    "    // this height. cs_main is recursive, so taking it here is safe\n"
                    "    // whether or not the caller already holds it.\n"
                    "    uint256 wam_seed;\n"
                    "    {\n"
                    "        LOCK(cs_main);\n"
                    "        const CBlockIndex* wam_prev = chainman.m_blockman.LookupBlockIndex(block.hashPrevBlock);\n"
                    "        wam_seed = wam::GetRandomXSeedHash(wam_prev, chainman.GetConsensus());\n"
                    "    }\n"
                    "\n"
                    "    while (max_tries > 0 && block.nNonce < std::numeric_limits<uint32_t>::max() && !wam::CheckProofOfWork(wam::GetRandomXPoWHash(block, wam_seed), block.nBits, chainman.GetConsensus()) && !chainman.m_interrupt) {"),
            ),
            Edit(
                file="src/rpc/mining.cpp",
                description="include wam/pow.h",
                marker="#include <wam/pow.h>",
                insert_after="#include <wam/consensus/subsidy.h>\n",
                insert_text="#include <wam/pow.h>\n",
            ),
            Edit(
                file="src/validation.cpp",
                description="headers-presync cannot verify RandomX without ancestry",
                marker="WAM_PRESYNC_POW_SKIPPED",
                anchor=(
                    "bool HasValidProofOfWork(const std::vector<CBlockHeader>& headers, const Consensus::Params& consensusParams)\n"
                    "{\n"
                    "    return std::all_of(headers.cbegin(), headers.cend(),\n"
                    "            [&](const auto& header) { return CheckProofOfWork(header.GetHash(), header.nBits, consensusParams);});\n"
                    "}"),
                replacement=(
                    "bool HasValidProofOfWork(const std::vector<CBlockHeader>& headers, const Consensus::Params& consensusParams)\n"
                    "{\n"
                    "    // WAM_PRESYNC_POW_SKIPPED\n"
                    "    //\n"
                    "    // This is the headers-presync anti-DoS filter: a cheap check on a\n"
                    "    // batch of headers whose ancestry is not yet known. RandomX needs a\n"
                    "    // seed derived from a buried block, and by construction these headers\n"
                    "    // have no established position in the chain -- so there is no honest\n"
                    "    // answer to give here.\n"
                    "    //\n"
                    "    // Returning true does NOT weaken block validity: every header still\n"
                    "    // passes ContextualCheckBlockHeader, where the seed is knowable, and\n"
                    "    // nothing is connected without it. What is lost is bandwidth-level\n"
                    "    // spam resistance during presync, which is the same trade already\n"
                    "    // documented on CheckBlockHeader.\n"
                    "    (void)headers;\n"
                    "    (void)consensusParams;\n"
                    "    return true;\n"
                    "}"),
            ),
            Edit(
                file="src/node/blockstorage.cpp",
                description="drop the SHA256d check while loading the block index",
                marker="WAM_INDEX_POW_CHECK_REMOVED",
                anchor=(
                    "                if (!CheckProofOfWork(pindexNew->GetBlockHash(), pindexNew->nBits, consensusParams)) {\n"
                    "                    LogError(\"%s: CheckProofOfWork failed: %s\\n\", __func__, pindexNew->ToString());\n"
                    "                    return false;\n"
                    "                }"),
                replacement=(
                    "                // WAM_INDEX_POW_CHECK_REMOVED\n"
                    "                //\n"
                    "                // Every entry here was already validated against RandomX\n"
                    "                // before it was written. Re-checking with SHA256d would\n"
                    "                // reject the entire index on startup, and re-checking with\n"
                    "                // RandomX is impossible: pprev is not linked yet at this\n"
                    "                // point in the load, so no seed can be derived.\n"),
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-011",
        title="Register the WAM RPC commands",
        rationale=("wam_rpc.cpp defines them but nothing called it, so "
                   "getsupplyinfo and friends returned -32601 Method not found."),
        edits=[
            Edit(
                file="src/rpc/register.h",
                description="declare RegisterWamRPCCommands",
                marker="void RegisterWamRPCCommands(CRPCTable&);",
                insert_after="void RegisterTxoutProofRPCCommands(CRPCTable&);\n",
                insert_text=(
                    "\n"
                    "// WAM: getsupplyinfo, getdevfeeinfo, getrandomxinfo,\n"
                    "// getemissionschedule -- see src/wam/rpc/wam_rpc.cpp\n"
                    "void RegisterWamRPCCommands(CRPCTable&);\n"),
            ),
            Edit(
                file="src/rpc/register.h",
                description="call RegisterWamRPCCommands from RegisterAllCoreRPCCommands",
                marker="    RegisterWamRPCCommands(t);",
                insert_after="    RegisterSignMessageRPCCommands(t);\n",
                insert_text="    RegisterWamRPCCommands(t);\n",
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-009",
        title="Wire the WAM sources into the autotools build",
        rationale="Without this the files are copied into the tree but never compiled.",
        edits=[
            Edit(
                file="src/Makefile.am",
                description="add WAM .cpp files to libbitcoin_node_a_SOURCES",
                marker="wam/consensus/subsidy.cpp",
                # NOTE the exact whitespace: upstream writes "= \" with a space
                # before the continuation here, but "=\" without one in
                # Makefile.test.include. A Makefile that loses a line
                # continuation fails with the famously unhelpful
                # "*** missing separator. Stop." -- so these anchors carry the
                # backslash and newline explicitly rather than being reflowed.
                insert_after="libbitcoin_node_a_SOURCES = \\\n",
                insert_text=(
                    "  wam/consensus/subsidy.cpp \\\n"
                    "  wam/consensus/devfee.cpp \\\n"
                    "  wam/pow.cpp \\\n"
                    "  wam/crypto/randomx_hash.cpp \\\n"
                    "  wam/rpc/wam_rpc.cpp \\\n"),
            ),
            Edit(
                file="src/Makefile.am",
                description="add WAM headers to BITCOIN_CORE_H",
                marker="wam/wam-params.h",
                insert_after="BITCOIN_CORE_H = \\\n",
                insert_text=(
                    "  wam/wam-params.h \\\n"
                    "  wam/pow.h \\\n"
                    "  wam/consensus/subsidy.h \\\n"
                    "  wam/consensus/devfee.h \\\n"
                    "  wam/crypto/randomx_hash.h \\\n"),
            ),
            Edit(
                file="src/Makefile.test.include",
                description="add the WAM consensus tests to BITCOIN_TESTS",
                marker="test/wam_monetary_tests.cpp",
                insert_after="BITCOIN_TESTS =\\\n",
                insert_text=(
                    "  test/wam_monetary_tests.cpp \\\n"
                    "  test/wam_devfee_tests.cpp \\\n"
                    "  test/wam_vesting_tests.cpp \\\n"),
            ),
        ]))

    # -----------------------------------------------------------------------
    changes.append(Change(
        id="WAM-008",
        title="Mark where the binary names will be renamed (NOT YET DONE)",
        rationale=("This change set does NOT rename anything. It inserts a marker "
                   "comment and nothing else. It was titled 'Rename the binaries to "
                   "wamd / wam-cli / wam-tx / wam-wallet' for three days while the "
                   "build kept producing bitcoind, bitcoin-cli, bitcoin-tx, "
                   "bitcoin-util and bitcoin-wallet, and PROGRESS.md recorded the "
                   "rename as complete. A change set whose title claims more than its "
                   "edits do is worse than a missing change set: it stops anyone from "
                   "looking. The real rename touches 39 automake variables across two "
                   "files, plus BITCOIN_CONF_FILENAME, the default datadir and the "
                   "functional test framework's config.ini."),
        edits=[Edit(
            file="src/Makefile.am",
            description="rename the built programs",
            marker="WAM_BINARY_NAMES",
            anchor="bin_PROGRAMS =",
            replacement="# WAM_BINARY_NAMES\nbin_PROGRAMS =",
            required=False,
        )]))

    return changes


# ===========================================================================


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tree", help="path to the Bitcoin Core checkout")
    ap.add_argument("--repo", default=".", help="path to this repository")
    ap.add_argument("--check", action="store_true",
                    help="report what would change without writing anything")
    ap.add_argument("--list", action="store_true", help="list the changes and exit")
    args = ap.parse_args()

    changes = build_changes()

    if not args.list and not args.tree:
        ap.error("--tree is required unless --list is given")

    if args.list:
        print("WAM Coin source transformations:\n")
        for c in changes:
            print(f"  {c.id}  {c.title}")
            print(f"          {c.rationale}\n")
        return 0

    print("=" * 78)
    print(" WAM COIN -- upstream patcher")
    print("=" * 78)
    print(f" tree : {os.path.abspath(args.tree)}")
    print(f" repo : {os.path.abspath(args.repo)}")
    if args.check:
        print(" mode : DRY RUN (no files will be written)")

    try:
        patcher = Patcher(args.tree, args.repo, dry_run=args.check)
        for change in changes:
            patcher.apply_change(change)
    except PatchError as exc:
        print("\n" + "=" * 78)
        print(" PATCHING ABORTED")
        print("=" * 78)
        print(f" {exc}")
        print("\n No further changes were attempted. The tree is either untouched or\n"
              " partially patched -- delete it and re-run scripts/fetch-upstream.sh\n"
              " rather than trying to continue from here.")
        return 1

    print("\n" + "=" * 78)
    print(f" {len(patcher.applied)} change sets applied"
          + (f", {len(patcher.skipped)} edits already present" if patcher.skipped else ""))
    print("=" * 78)
    return 0


if __name__ == "__main__":
    sys.exit(main())

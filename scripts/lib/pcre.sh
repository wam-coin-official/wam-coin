# shellcheck shell=bash
# ===========================================================================
#  lib/pcre.sh -- refuse to run if grep -P is not available
# ===========================================================================
#
#      . "$SCRIPTS_DIR/lib/pcre.sh"
#
#  WHY THIS EXISTS
#
#  On 5 September 2026 audit_repo.sh reported, twice, that
#  docs/LISTING_PACKAGE.md carried hashes that were "neither a genesis hash nor
#  labelled". Both hashes were the real mainnet and testnet genesis hashes.
#
#  The check reads the declared hashes out of chainparams.cpp with
#
#      grep -oP 'hashGenesisBlock == uint256S\("0x\K[0-9a-f]{64}'
#
#  and on this machine grep answers
#
#      grep: -P supports only unibyte and UTF-8 locales
#
#  and exits without printing anything. The list of declared hashes came back
#  EMPTY, so every hash in every published document failed the comparison. The
#  audit accused correct consensus values of being wrong, using a tool that had
#  already told it that it could not answer.
#
#  That is the same shape as the other two faults found the same hour: python3
#  resolving to a Store stub that exits 49, and `bash` resolving to the WSL
#  stub that runs nothing. In all three the tool did not fail -- it succeeded
#  at producing nothing, and the caller read nothing as a finding.
#
#  A check that cannot run must say so. It must never quietly become a check
#  that fails.
#
#  psbt_rehearsal.sh and import_founder_key.sh matter more than the audit here:
#  they pull "psbt", "hex" and "checksum" out of wallet RPC output the same way,
#  in the flow that signs with the founder key. An empty capture there is not a
#  false alarm, it is a silent wrong value in a signing step.
# ===========================================================================

if ! printf 'x' | grep -qoP 'x' 2>/dev/null; then
    printf 'error: this script needs grep -P (PCRE) and it is unavailable.\n' >&2
    printf '       grep said: %s\n' \
        "$(printf 'x' | grep -oP 'x' 2>&1 | head -1)" >&2
    printf '       Usually the locale: LANG is unset or is not UTF-8, and\n' >&2
    printf '       GNU grep then refuses -P rather than guessing.\n' >&2
    printf '       Try:  LANG=C.UTF-8 bash %s\n' "${BASH_SOURCE[1]:-$0}" >&2
    printf '\n' >&2
    printf '       Refusing to continue. Without -P the patterns here capture\n' >&2
    printf '       nothing, and nothing compares equal to nothing -- which is\n' >&2
    printf '       how this reported that a correct genesis hash was wrong.\n' >&2
    return 2 2>/dev/null || exit 2
fi

# Mainnet launch checklist

Everything here is irreversible once the first block is mined. Work through it in order.

---

## Phase 1 — Before generating any key

- [ ] `python3 scripts/verify_supply.py --schedule` passes, and the printed terminal supply
      matches what the whitepaper claims.
- [ ] `python3 genesis/test_serialization.py` passes (proves the serializer against
      Bitcoin's real genesis hash).
- [ ] `python3 scripts/gen_founder_key.py --selftest` passes.
- [ ] `python3 scripts/patch_upstream.py --list` — read all nine changes and understand
      each one. Do not skip WAM-004 and WAM-005.
- [ ] A testnet has been running for **at least two weeks** with more than one independent
      node, and has crossed at least one RandomX epoch rotation without a fork.
- [ ] `./src/test/test_bitcoin --run_test=wam_monetary_tests,wam_devfee_tests` passes.
- [ ] `node pool/test/rewards.test.js` passes.

## Phase 2 — Founder key custody

- [ ] Key generated on an **air-gapped** machine that has never been on a network.
      `gen_founder_key.py` refuses to mint a mainnet key when it detects a network
      route; do not use `--i-accept-online-key-generation` to get past that.
- [ ] The generator was run **bare** — its output was NOT piped through `grep`,
      `tee`, `head`, or anything else. A pipe filters the WIF out of view while
      the address survives, which loses the key permanently once the address is
      committed to the genesis block. (This happened during testnet rehearsal.)
- [ ] The address was **never retyped or copied by hand.** Write it to a file on
      the offline machine, carry it on USB, and re-verify its base58 checksum on
      the receiving machine before use. During rehearsal, two consecutive manual
      copies of the testnet address were corrupted — once by an extra character,
      once by `K` in place of `k`. Either would have burned the entire premine.
- [ ] WIF transcribed to paper or steel; **never** photographed, pasted, or stored in a
      cloud note, password manager sync, chat, or ticket.
- [ ] At least two geographically separate physical copies exist.
- [ ] Recovery has been rehearsed: the address was re-derived from the written-down WIF on
      a clean machine and matched.
- [ ] A migration plan to **multi-signature** custody exists and is dated. A single key
      controlling 12.50% of the supply — including four time-locked tranches that cannot be
      moved to a new key before their unlock dates — is a standing liability.
- [ ] The `--out` file, if used, has been securely erased (`shred -u`), and the terminal
      scrollback is cleared.

## Phase 3 — Chain parameters

- [ ] `WAM_FOUNDER_ADDRESS_MAINNET` set in `src/wam/chainparams.cpp`; it starts with `W`
      and is 34 characters.
- [ ] The address was verified by decoding it independently, not by eyeballing it.
- [ ] `WAM_FOUNDER_ADDRESS_TESTNET` set separately (a mainnet address on testnet is a
      launch-day embarrassment).
- [ ] **Launch date confirmed as 2026-09-15** and `WAM_GENESIS_TIME` matches it. Every
      vesting unlock is an anniversary of this value; changing it after genesis is mined is
      a hard fork.
- [ ] Genesis mined:
      `python3 genesis/genesis_generator.py --network mainnet --address W... --patch ...`
- [ ] The generator printed **five** premine outputs with the expected unlock dates
      (2027/2028/2029/2030-09-15) and the first one unlocked.
- [ ] The generator's self-check passed (mined hash ≤ target, header exactly 80 bytes).
- [ ] `chainparams.cpp` now contains a real `nNonce` and both assertions have real hashes.
- [ ] A **second person** independently re-ran the generator with the same `--time`,
      `--bits` and `--address` and got the same nonce and hash.

## Phase 4 — Seed infrastructure

- [ ] At least **three** DNS seed hostnames resolve to running nodes, on separate providers
      and separate ASNs.
- [ ] Each seed node has `listen=1`, port 9555 open, and a static address.
- [ ] `vSeeds` in `chainparams.cpp` matches the hostnames that actually exist.
- [ ] `chainparamsseeds.h` is left empty for launch — fixed seeds are regenerated from real
      peer data in a later release, never invented.

## Phase 5 — First blocks

- [ ] Genesis validated: start `wamd`, confirm it does not assert, and that
      `getblockhash 0` matches the value in `chainparams.cpp`.
- [ ] `getsupplyinfo` reports `circulating = 2,000,000` at height 0.
- [ ] `getsupplyinfo` reports `founder_vesting.unlocked = 400,000` and `locked = 1,600,000`
      at launch.
- [ ] **Tranche 1 is spendable**: after 100 confirmations, spend from the unlocked
      400,000 WAM output on a private copy of the chain. If WAM-005 did not apply, this is
      where you find out — and it is unfixable after launch.
- [ ] **Tranches 2–5 are NOT spendable**: attempt to spend a locked output and confirm the
      node rejects it (`non-final` / CLTV failure). A lock you have not seen refuse a spend
      is a lock you do not have.
- [ ] `getblock <genesis> 2` shows five outputs, and the four locked `scriptPubKey`s
      visibly contain their unlock timestamps in bare CLTV form (no P2SH hash).
- [ ] Mine blocks 1–30 and confirm with `getdevfeeinfo "<hash>"` that every one paid the
      treasury and reports `compliant: true`.
- [ ] Deliberately mine an **invalid** block that omits the treasury output and confirm the
      node rejects it with `bad-cb-devfee-amount`. A rule you have not seen fire is a rule
      you do not have.
- [ ] On a throwaway chain with a lowered `WAM_DEVFEE_LAST_HEIGHT`, confirm that the block
      immediately after the sunset is accepted **without** a treasury output, and that
      `getdevfeeinfo` reports `active_now: false`. The expiry is a promise to miners; test
      it before making it.
- [ ] Difficulty responds: point 10× the hash rate at the chain for 30 blocks and confirm
      DGW pulls it up, then remove it and confirm recovery.

## Phase 6 — Pool

- [ ] `poolAddress` in `pool/config.json` is a real mainnet address you control, and is
      **not** the founder address.
- [ ] The pool starts and logs `devfee` values from `getblocktemplate`. If it refuses to
      start, the daemon is unpatched — fix the daemon, never the pool's check.
- [ ] A test miner connected, submitted shares, and appears on the dashboard.
- [ ] A payment run completed end to end on testnet, including a block maturing from
      pending → confirmed → paid.
- [ ] An orphaned block was simulated and the pool correctly paid nobody for it.
- [ ] The dashboard is behind TLS if it is publicly reachable.
- [ ] RPC port 9556 is **not** reachable from the internet.
- [ ] The pool wallet is separate from any personal wallet and holds only working balance.

## Phase 7 — Public

- [ ] `WHITEPAPER.md` published, including §8 (limitations) **unedited**. Removing the
      honest limitations section is the single clearest signal that a project should not be
      trusted.
- [ ] The **12.50%** total founder + operating allocation is stated prominently in the same
      table as its two components — never split across sections so that a reader has to add
      them up. Presenting the parts without the total is what makes a fair number look like
      a concealed one.
- [ ] The vesting schedule and the block-400,000 fee expiry are published as *verifiable
      commands*, not prose: `wam-cli getsupplyinfo` and `getblock <genesis> 2`.
- [ ] The genesis hash, merkle root and treasury address are published so anyone can verify
      them against their own node.
- [ ] A block explorer is live.
- [ ] A binary release is published with SHA256 sums and the exact upstream commit that was
      built (`build/wam-core/.wam-patched`).
- [ ] A security contact address exists and is monitored.

## Ongoing

- [ ] Subscribe to Bitcoin Core security announcements. This fork inherits upstream
      vulnerabilities; a fork that stops merging upstream fixes becomes dangerous.
- [ ] Populate `nMinimumChainWork` and `defaultAssumeValid` in a release once the chain has
      real accumulated work.
- [ ] Regenerate `chainparamsseeds.h` from real peer data once peers are stable.
- [ ] Publish a treasury spending report on a fixed cadence. The consensus layer enforces
      that the 5% is *collected*; only disclosure shows what it was *used for*.

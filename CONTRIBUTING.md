# Contributing to WAM Coin

Patches, bug reports and review are all welcome. Security issues are not — those
go to [SECURITY.md](SECURITY.md), privately.

## Before anything else: how this repository is built

WAM is a fork of Bitcoin Core v28.1, and it is **not a copy of it**. Upstream is
downloaded and then transformed by a script:

```bash
bash scripts/fetch-upstream.sh              # clone Bitcoin Core v28.1
python3 scripts/patch_upstream.py --tree build/wam-core --repo .
```

`scripts/patch_upstream.py` holds every change WAM makes to upstream as a named
change set with an anchor, a marker and a reason. Nothing is a `.patch` file,
because a diff tells you *what* changed and never *why*.

**This means: do not edit `build/wam-core/` and send that.** It is generated, and
your change will be lost the next time anyone re-runs the script. Edit the change
set, or edit the WAM sources in `src/wam/`, and let the script apply them.

Run `python3 scripts/patch_upstream.py --list` to read every change WAM makes to
Bitcoin, in about ten minutes. If you are reviewing this project for the first
time, read that list before you read any code.

## Building

```bash
bash scripts/build.sh          # node, cli, tools
bash scripts/build_qt.sh       # add the graphical wallet (needs Qt5 dev packages)
bash miner/build.sh            # the reference miner
```

See [docs/BUILD.md](docs/BUILD.md) for prerequisites.

## Tests, and what a patch has to pass

```bash
./build/wam-core/src/test/test_bitcoin --run_test=wam_*        # consensus units
python3 build/wam-core/test/functional/test_runner.py feature_wam_devfee \
        feature_wam_genesis feature_wam_pow                    # functional
node pool/test/rewards.test.js                                 # pool
./miner/wam-miner --self-test                                  # miner
python3 scripts/verify_supply.py --check-constants             # cross-language
```

That last one matters more than it looks. WAM's monetary constants exist in C++,
in JavaScript and in Python, and `--check-constants` fails the moment they
disagree. A patch that changes one and not the others will be rejected by the
script before a human sees it.

## Things this project has learned the hard way

These are not style preferences. Each one is a bug that shipped.

**If the daemon returns it, do not recompute it.** The emission schedule, the
treasury amount and the RandomX epoch are all reported by `getblocktemplate` and
`getsupplyinfo`. Reimplementing any of them in JavaScript produced four separate
bugs — a pool that destroyed 5% of every block it mined, a pool that rotated its
mining key 1,840 blocks early, and two dashboards that reported a 50 WAM block
reward on a chain paying 74 satoshi.

**A test that asserts the wrong answer is worse than no test.** BIP34 height
encoding was wrong for heights 1–16 — exactly the first blocks of a chain — and
survived because a unit test asserted the wrong bytes and passed.

**A rule that is implemented but never reached is not a rule.** Proof of work was
computed with RandomX and compared with SHA256d for a while. Every unit test
passed. `test/functional/feature_wam_pow.py` exists to make that impossible to
repeat, and it is the model for testing anything consensus-critical: drive a real
node and check what it actually rejects.

**Say what a change does, not what you meant it to do.** A change set titled
"Rename the binaries" that only inserted a comment left the project convinced for
three days that its programs were called `wamd`.

## Style

Match the file you are editing. The C++ follows Bitcoin Core's conventions
because most of it is Bitcoin Core; the JavaScript and Python follow whatever the
neighbouring code does.

Comments explain **why**. The code already says what. A comment that restates the
line above it will be asked about in review.

## Commits

One logical change per commit. A message that says what changed and why, in
prose, wrapped at 72 columns. If the change fixes a bug, describe what the bug
would have caused — that sentence is worth more in two years than the diff.

## What is deliberately out of scope

* **GPU mining.** RandomX is designed to run poorly on GPUs. Half-speed CUDA
  support would only invite people to spend electricity for nothing.
* **A developer fee in the miner.** `miner/` mines to the address you give it and
  to no other, and that will not change. WAM's treasury is a consensus rule paid
  by the coinbase, visible in every block, ending at height 400,000.
* **Changing the monetary policy.** 22,000,000 cap, 200,000-block halving,
  2,000,000 premine vested to 2030. These are the terms anyone who mines this
  chain agreed to. A patch that alters them is a proposal for a different coin.

## Licence

MIT, the same as Bitcoin Core. By contributing you agree your work is released
under it.

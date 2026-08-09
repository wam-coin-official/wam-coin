# Building WAM Coin from source

`./install.sh` does everything below automatically on Ubuntu 22.04. This document is for
other distributions, for CI, and for anyone who wants to know what the installer is doing.

---

## 1. Dependencies

### Ubuntu 22.04 / Debian 12

```bash
sudo apt-get install -y \
    build-essential libtool autotools-dev automake pkg-config bsdmainutils \
    cmake curl git python3 \
    libevent-dev libboost-dev libssl-dev libsqlite3-dev libzmq3-dev
```

### Fedora / RHEL 9

```bash
sudo dnf install -y \
    gcc-c++ libtool make autoconf automake cmake git python3 \
    libevent-devel boost-devel openssl-devel sqlite-devel zeromq-devel
```

### Arch

```bash
sudo pacman -S base-devel cmake git python libevent boost openssl sqlite zeromq
```

For the pool, additionally: **Node.js ≥ 18** and **Redis**.

Then run the installer with `--skip-deps`.

---

## 2. Verify before you compile

There is no point building a binary whose arithmetic does not hold:

```bash
python3 scripts/verify_supply.py            # the 22,000,000 cap
python3 scripts/gen_founder_key.py --selftest   # address prefix table
python3 genesis/test_serialization.py       # genesis serializer vs. Bitcoin's real genesis
```

All three must pass. `install.sh` runs them before invoking the compiler.

---

## 3. Fetch upstream and apply the WAM changes

```bash
./scripts/fetch-upstream.sh
```

This:

1. clones **tevador/RandomX v1.2.1** into `build/randomx` and builds `librandomx.a`,
2. clones **bitcoin/bitcoin v28.1** (shallow) into `build/wam-core`,
3. runs `scripts/patch_upstream.py`, which applies nine anchored transformations,
4. writes `build/wam-core/.wam-patched` recording the exact upstream commit.

The upstream tag is **pinned**. Never track a branch — a consensus layer that changes
underneath you between two builds is not a consensus layer.

To see exactly what will be changed before anything is written:

```bash
python3 scripts/patch_upstream.py --list
python3 scripts/patch_upstream.py --tree build/wam-core --repo . --check
```

### If the patcher aborts

You will see something like:

```
src/validation.cpp: anchor for 'delegate the subsidy to wam::GetBlockSubsidy' not found.
```

This means upstream moved the code. **Do not loosen the anchor to make it apply.** Open the
current source, confirm the change still belongs where you think it does, and update the
anchor in `scripts/patch_upstream.py`. A consensus edit landing in the wrong function is
exactly the failure mode this design exists to prevent.

The patcher is idempotent and aborts before writing anything on the first problem, so a
failed run leaves the tree usable.

---

## 4. Compile

```bash
cd build/wam-core
./autogen.sh
./configure --without-gui \
    CPPFLAGS="-I$PWD/../randomx/src" \
    LIBS="$PWD/../randomx/build/librandomx.a -lpthread"
make -j"$(nproc)"
```

Expect 10–40 minutes. Peak memory is roughly 1.5 GB per compile job — on a machine with
4 GB, use `make -j2` rather than `-j$(nproc)`.

---

## 5. Test

```bash
./src/test/test_bitcoin --run_test=wam_monetary_tests,wam_devfee_tests
```

`wam_monetary_tests` covers the emission schedule, epoch boundaries, the hard cap, and the
subsidy/treasury split across all 33 epochs.

`wam_devfee_tests` covers consensus rule WAM-1, including the cases that matter: omitting
the treasury output, underpaying it by a single base unit, and paying the correct amount to
the *wrong* script.

The full upstream suite is also worth running once:

```bash
make check
```

---

## 6. Install

```bash
sudo make install
sudo ln -sf /usr/local/bin/bitcoind    /usr/local/bin/wamd
sudo ln -sf /usr/local/bin/bitcoin-cli /usr/local/bin/wam-cli
```

---

## 7. Build the pool's native addon

```bash
cd pool
npm install
cd native
RANDOMX_INCLUDE="$PWD/../../build/randomx/src" \
RANDOMX_LIB="$PWD/../../build/randomx/build/librandomx.a" \
    npx node-gyp rebuild
```

There is deliberately **no pure-JavaScript fallback**. A pool that silently degraded to a
fake hash function would accept every share and pay out on work nobody did.

---

## Troubleshooting

**`randomx.h: No such file or directory`**
`CPPFLAGS` is not pointing at `build/randomx/src`. That directory is the include root, not
`build/randomx`.

**`undefined reference to randomx_calculate_hash`**
`librandomx.a` is missing from `LIBS`, or it appears *before* the objects that use it.
Static archives must come after their consumers on the link line.

**`assert(consensus.hashGenesisBlock == uint256S("0x0000..."))` fails at startup**
The genesis block has not been mined yet, or `chainparams.cpp` was edited after mining.
Re-run `genesis/genesis_generator.py --patch`.

**`the founder address is not a valid base58check address`**
`WAM_FOUNDER_ADDRESS_MAINNET` is still the placeholder. This is intentional — see
§"Launching a real chain" in the README.

**`randomx_alloc_dataset failed`**
Full-dataset mode needs ~2.1 GiB free. Set `randomxmining=0` (validation only needs
256 MiB), or use `--light` in the genesis generator.

**The build OOMs**
Lower the job count. `make -j2` on 4 GB, `-j4` on 8 GB.

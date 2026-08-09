#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""
randomx_ffi.py -- a thin, honest ctypes binding to librandomx.

This is the same library (tevador/RandomX) that wamd links against, so a hash
produced here is bit-identical to one produced by the C++ node. That property
is the whole point: the genesis block mined by this script must validate under
the daemon without a single byte of special-casing.

Why ctypes rather than a pip package: there is no maintained RandomX wheel that
tracks upstream, and a genesis block is a one-shot artifact that the entire
chain's identity depends on. Binding directly to the exact .so that the node
uses removes an entire class of "the pure-Python reimplementation was subtly
wrong" failures.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import os
import platform
import sys

# --- RandomX flags (randomx.h) ---------------------------------------------
RANDOMX_FLAG_DEFAULT      = 0
RANDOMX_FLAG_LARGE_PAGES  = 1
RANDOMX_FLAG_HARD_AES     = 2
RANDOMX_FLAG_FULL_MEM     = 4
RANDOMX_FLAG_JIT          = 8
RANDOMX_FLAG_SECURE       = 16
RANDOMX_FLAG_ARGON2_SSSE3 = 32
RANDOMX_FLAG_ARGON2_AVX2  = 64

RANDOMX_HASH_SIZE = 32


class RandomXError(RuntimeError):
    pass


def _candidate_paths() -> list[str]:
    """Places librandomx may live, most specific first."""
    env = os.environ.get("WAM_LIBRANDOMX")
    out = [env] if env else []

    system = platform.system()
    if system == "Windows":
        names = ["randomx.dll", "librandomx.dll"]
    elif system == "Darwin":
        names = ["librandomx.dylib"]
    else:
        names = ["librandomx.so"]

    here = os.path.dirname(os.path.abspath(__file__))
    roots = [
        os.path.join(here, "..", "depends", "randomx", "build"),
        os.path.join(here, "..", "build", "randomx"),
        "/usr/local/lib",
        "/usr/lib",
        "/usr/lib/x86_64-linux-gnu",
    ]
    for root in roots:
        for name in names:
            out.append(os.path.normpath(os.path.join(root, name)))

    for name in names:
        found = ctypes.util.find_library(name.replace("lib", "").replace(".so", "")
                                         .replace(".dylib", "").replace(".dll", ""))
        if found:
            out.append(found)
        out.append(name)  # let the loader search

    return out


def load_library() -> ctypes.CDLL:
    errors = []
    for path in _candidate_paths():
        try:
            return ctypes.CDLL(path)
        except OSError as exc:  # not present / wrong arch
            errors.append(f"  {path}: {exc}")

    raise RandomXError(
        "Could not load librandomx.\n"
        "Build it once with:\n"
        "    git clone https://github.com/tevador/RandomX depends/randomx\n"
        "    cmake -S depends/randomx -B depends/randomx/build -DARCH=native\n"
        "    cmake --build depends/randomx/build -j$(nproc)\n"
        "or set WAM_LIBRANDOMX=/path/to/librandomx.so\n\n"
        "Tried:\n" + "\n".join(errors)
    )


def _bind(lib: ctypes.CDLL) -> ctypes.CDLL:
    """Declare argtypes/restypes so ctypes does not silently truncate pointers
    to 32 bits on 64-bit builds -- a classic and very hard to debug failure."""
    lib.randomx_get_flags.restype = ctypes.c_int
    lib.randomx_get_flags.argtypes = []

    lib.randomx_alloc_cache.restype = ctypes.c_void_p
    lib.randomx_alloc_cache.argtypes = [ctypes.c_int]

    lib.randomx_init_cache.restype = None
    lib.randomx_init_cache.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]

    lib.randomx_release_cache.restype = None
    lib.randomx_release_cache.argtypes = [ctypes.c_void_p]

    lib.randomx_alloc_dataset.restype = ctypes.c_void_p
    lib.randomx_alloc_dataset.argtypes = [ctypes.c_int]

    lib.randomx_dataset_item_count.restype = ctypes.c_ulong
    lib.randomx_dataset_item_count.argtypes = []

    lib.randomx_init_dataset.restype = None
    lib.randomx_init_dataset.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                         ctypes.c_ulong, ctypes.c_ulong]

    lib.randomx_release_dataset.restype = None
    lib.randomx_release_dataset.argtypes = [ctypes.c_void_p]

    lib.randomx_create_vm.restype = ctypes.c_void_p
    lib.randomx_create_vm.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]

    lib.randomx_destroy_vm.restype = None
    lib.randomx_destroy_vm.argtypes = [ctypes.c_void_p]

    lib.randomx_calculate_hash.restype = None
    lib.randomx_calculate_hash.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                           ctypes.c_size_t, ctypes.c_void_p]
    return lib


class RandomXContext:
    """
    Owns one cache (and optionally one 2 GiB dataset) for a single key.

    VMs are NOT thread-safe, but a dataset is read-only once built and may be
    shared. `new_vm()` therefore hands each worker thread its own VM over the
    shared dataset -- which is exactly how a real miner is structured.
    """

    def __init__(self, key: bytes, full_mem: bool = True, threads: int = 0,
                 verbose: bool = True):
        self.lib = _bind(load_library())
        self.full_mem = full_mem
        self._vms: list[int] = []
        self.dataset = None

        flags = self.lib.randomx_get_flags()
        if full_mem:
            flags |= RANDOMX_FLAG_FULL_MEM
        else:
            flags &= ~RANDOMX_FLAG_FULL_MEM
        self.flags = flags

        self.cache = self.lib.randomx_alloc_cache(flags)
        if not self.cache:
            raise RandomXError("randomx_alloc_cache failed (out of memory?)")
        self.lib.randomx_init_cache(self.cache, key, len(key))

        if full_mem:
            self.dataset = self.lib.randomx_alloc_dataset(flags)
            if not self.dataset:
                self.lib.randomx_release_cache(self.cache)
                raise RandomXError(
                    "randomx_alloc_dataset failed. Full-dataset mode needs ~2.1 GiB of "
                    "free RAM. Re-run with --light to mine from the 256 MiB cache "
                    "instead (about 8x slower, but it will finish)."
                )
            self._init_dataset(threads, verbose)

    def _init_dataset(self, threads: int, verbose: bool) -> None:
        import threading

        count = self.lib.randomx_dataset_item_count()
        if threads <= 0:
            threads = os.cpu_count() or 1

        if verbose:
            print(f"[randomx] building 2 GiB dataset with {threads} threads "
                  f"({count:,} items)...", file=sys.stderr, flush=True)

        # ctypes releases the GIL around the call, so these really do run in
        # parallel across cores.
        workers = []
        per = count // threads
        start = 0
        for i in range(threads):
            n = (count - start) if i == threads - 1 else per
            t = threading.Thread(target=self.lib.randomx_init_dataset,
                                 args=(self.dataset, self.cache, start, n),
                                 daemon=True)
            workers.append(t)
            t.start()
            start += n
        for t in workers:
            t.join()

        if verbose:
            print("[randomx] dataset ready.", file=sys.stderr, flush=True)

    def new_vm(self) -> int:
        vm = self.lib.randomx_create_vm(self.flags, self.cache, self.dataset)
        if not vm:
            raise RandomXError("randomx_create_vm failed")
        self._vms.append(vm)
        return vm

    def hash_with(self, vm: int, data: bytes) -> bytes:
        out = ctypes.create_string_buffer(RANDOMX_HASH_SIZE)
        self.lib.randomx_calculate_hash(vm, data, len(data), out)
        return out.raw[:RANDOMX_HASH_SIZE]

    def hash(self, data: bytes) -> bytes:
        """Convenience single-threaded hash using a lazily created VM."""
        if not self._vms:
            self.new_vm()
        return self.hash_with(self._vms[0], data)

    def close(self) -> None:
        for vm in self._vms:
            self.lib.randomx_destroy_vm(vm)
        self._vms.clear()
        if self.dataset:
            self.lib.randomx_release_dataset(self.dataset)
            self.dataset = None
        if self.cache:
            self.lib.randomx_release_cache(self.cache)
            self.cache = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


if __name__ == "__main__":
    # Official RandomX test vector (README.md of tevador/RandomX):
    #   key   = "test key 000"
    #   input = "This is a test"
    #   hash  = 639183aae1bf4c9a35884cb46b09cad9175f04efd7684e7262a0ac1c2f0b4e3f
    expected = "639183aae1bf4c9a35884cb46b09cad9175f04efd7684e7262a0ac1c2f0b4e3f"
    with RandomXContext(b"test key 000", full_mem=False, verbose=False) as ctx:
        got = ctx.hash(b"This is a test").hex()
    print(f"expected {expected}")
    print(f"got      {got}")
    if got != expected:
        sys.exit("FAIL: librandomx does not match the reference test vector")
    print("OK: librandomx matches the reference test vector")

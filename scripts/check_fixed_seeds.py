#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_fixed_seeds.py -- do the addresses inside the binary answer?
# ===========================================================================
#
#      python3 scripts/check_fixed_seeds.py
#      python3 scripts/check_fixed_seeds.py --network mainnet
#
#  WHY THIS EXISTS, AND WHY IT IS NOT check_reachable.sh
#
#  check_reachable.sh asks whether a port you name is reachable from a vantage
#  point you name. It is the right tool and it found a real fault in August.
#  It also cannot tell you that you named the wrong host.
#
#  These addresses are different in kind: they are compiled into every copy of
#  the software and cannot be withdrawn from a binary somebody already
#  downloaded. v0.1.7 put them there so a node can find the network when DNS
#  cannot be trusted. If one of them stops answering, every new node that
#  falls back to it fails silently -- and there is no second chance, because
#  the address is inside the program.
#
#  So the targets are read out of src/wam/chainparamsseeds.h rather than typed
#  in. A check whose targets are arguments is a check that tests whatever
#  somebody remembered.
#
#  MAINNET BEFORE LAUNCH
#
#  Nothing listens on 9555 until 15 September 2026, and that is correct rather
#  than broken. Reported as "not yet", with the date, and not as a pass:
#  the whole point is that it must be true on the morning it matters, and
#  the seeds inside every binary already published point there.
#
#  On 6 September both mainnet seeds refused the connection, which is exactly
#  what they should do -- and is also exactly what a launch-day failure would
#  look like, which is why this prints the date instead of a tick.
# ===========================================================================

import argparse
import datetime
import pathlib
import re
import socket
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent

sys.path.insert(0, str(REPO / "scripts" / "lib"))
import quoted  # noqa: E402  -- needs the path above


def _read(p):
    """Read a source file with the author's quotations blanked.

    Both of these checks match values out of C++ that also has comments in
    it, and the comment beside a value is exactly where somebody explains an
    old one. See scripts/lib/quoted.py.
    """
    return quoted.strip_quoted(pathlib.Path(p).read_text(encoding="utf-8", errors="replace"))
SEEDS = REPO / "src" / "wam" / "chainparamsseeds.h"

LAUNCH = datetime.datetime(2026, 9, 15, 0, 0, tzinfo=datetime.timezone.utc)

GRN, RED, YLW, BLD, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[0m"

_fails = []


def ok(m):   print(f"  {GRN}ok{OFF}    {m}")
def bad(m):  print(f"  {RED}FAIL{OFF}  {m}"); _fails.append(m)
def warn(m): print(f"  {YLW}!!{OFF}    {m}")


def decode(array_name):
    """The addresses actually compiled in, read from the generated header.

    BIP155 layout, one entry after another: network id, address length, the
    address bytes, then the port big-endian. Only IPv4 (network 1) is emitted
    by contrib/seeds/generate-seeds.py for this project; anything else here
    would be a surprise worth stopping for rather than skipping.
    """
    text = _read(SEEDS)
    m = re.search(re.escape(array_name) + r"\[\]\s*=\s*\{(.*?)\};", text, re.S)
    if not m:
        return None
    body = [int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", m.group(1))]
    out, i = [], 0
    while i + 4 <= len(body):
        net, ln = body[i], body[i + 1]
        if i + 2 + ln + 2 > len(body):
            break
        addr = body[i + 2:i + 2 + ln]
        port = (body[i + 2 + ln] << 8) | body[i + 3 + ln]
        if net == 1 and ln == 4:
            out.append((".".join(str(b) for b in addr), port))
        else:
            out.append((f"<network {net}, {ln} bytes>", port))
        i += 2 + ln + 2
    return out


def reachable(host, port, timeout=8):
    s = socket.socket()
    s.settimeout(timeout)
    t0 = time.time()
    try:
        s.connect((host, port))
        return True, (time.time() - t0) * 1000, None
    except Exception as e:
        return False, (time.time() - t0) * 1000, type(e).__name__
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--network", default="all",
                    choices=["all", "mainnet", "testnet"])
    args = ap.parse_args()

    print(f"\n{BLD}the seed addresses compiled into the binary answer{OFF}")

    if not SEEDS.exists():
        bad(f"{SEEDS} is not here -- nothing was checked")
        print()
        return 2

    now = datetime.datetime.now(datetime.timezone.utc)
    before_launch = now < LAUNCH

    wanted = [("mainnet", "chainparams_seed_main"),
              ("testnet", "chainparams_seed_test")]
    if args.network != "all":
        wanted = [w for w in wanted if w[0] == args.network]

    checked = 0
    for net, array in wanted:
        seeds = decode(array)
        if seeds is None:
            bad(f"{array} is not in chainparamsseeds.h")
            continue
        if not seeds:
            bad(f"{net}: no fixed seeds are compiled in at all. A node that "
                f"cannot reach DNS has nothing to fall back to.")
            continue

        print(f"\n  {BLD}{net}{OFF}")
        for host, port in seeds:
            checked += 1
            up, ms, why = reachable(host, port)
            if up:
                ok(f"{host}:{port}  {ms:.0f} ms")
            elif net == "mainnet" and before_launch:
                days = (LAUNCH - now).days
                warn(f"{host}:{port}  {why} -- nothing listens until "
                     f"{LAUNCH:%Y-%m-%d} ({days} days)")
            else:
                bad(f"{host}:{port} does not answer ({why}). This address is "
                    f"inside every copy of the software already downloaded and "
                    f"cannot be withdrawn from one.")

    if checked == 0:
        bad("no seed was tested -- this proves nothing")
        print()
        return 2

    print()
    if _fails:
        print(f"  {RED}{len(_fails)} finding(s){OFF}\n")
        return 1
    if before_launch and args.network in ("all", "mainnet"):
        print(f"  {GRN}every testnet seed answers{OFF}; mainnet opens "
              f"{LAUNCH:%Y-%m-%d}, and these two addresses are already inside\n"
              f"  every published binary. On that morning they must listen.\n")
        return 0
    print(f"  {GRN}{BLD}every address inside the binary answers{OFF}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""
WAM Coin classes for ElectrumX.

Appended to `src/electrumx/lib/coins.py` by integration/electrumx/install.sh.

It lives here rather than as an edit made once on a server, for the same reason
every other parameter in this repository does: a value that exists only on one
machine is a value nobody can check, and the next person to rebuild that
machine gets a different chain.

WHY THE TWO OVERRIDES IN WAMCoin

ElectrumX 2.0 targets Bitcoin Core 31 and requires a `txospenderindex`, which
Core 31 added for Electrum protocol 1.7. WAM is forked from Core v28.1 and has
neither, so an unmodified ElectrumX refuses to start against it.

Lowering both was tested rather than assumed: the server starts, syncs the
mempool, serves `server.version`, `blockchain.headers.subscribe`,
`server.features` and `blockchain.block.header`, and every answer matches what
the node reports. The index is used by protocol 1.7 features this chain does
not serve.

If a future ElectrumX starts using it unconditionally, the server will fail
loudly on start-up rather than serve wrong answers, which is the failure mode
to want.

WHY THE SEGWIT DESERIALIZER APPLIES UNCHANGED

RandomX changes how a header is *proved*, not how it is parsed. The header is
Bitcoin's 80 bytes with the nonce at offset 76; the block id is still the
double-SHA256 of that header, and only the proof-of-work hash is RandomX. The
transaction format, the script language and SegWit are all Bitcoin's.
"""

WAM_CLASSES = '''

class WAMCoin(Coin):
    """WAM Coin -- RandomX proof of work, forked from Bitcoin Core v28.1."""
    NAME = "WAMCoin"
    SHORTNAME = "WAM"
    NET = None                       # abstract base
    DESERIALIZER = lib_tx.DeserializerSegWit
    BASIC_HEADER_SIZE = 80

    # See the module docstring: WAM is Core v28.1, and both of these exist for
    # protocol 1.7 against Core 31.
    MIN_REQUIRED_DAEMON_VERSION = "0.1"
    REQUIRED_DAEMON_INDEXES = ("txindex",)


class WAMCoinMainnet(WAMCoin):
    NET = "mainnet"
    RPC_PORT = 9554
    P2PKH_VERBYTE = bytes.fromhex("49")          # 73 -> addresses start 'W'
    P2SH_VERBYTES = (bytes.fromhex("87"),)       # 135 -> 'w'
    WIF_BYTE = bytes.fromhex("be")               # 190 -> keys start 'V'
    XPUB_VERBYTES = bytes.fromhex("0488b21e")
    XPRV_VERBYTES = bytes.fromhex("0488ade4")
    GENESIS_HASH = ("d8d3debea987b62a0934c3980d62bffbb"
                    "6e16aa797d19891d4fcc9b9fb11d7e9")
    TX_COUNT = 1
    TX_COUNT_HEIGHT = 1
    TX_PER_BLOCK = 2
    PEERS = []


class WAMCoinTestnet(WAMCoin):
    NET = "testnet"
    RPC_PORT = 19554
    P2PKH_VERBYTE = bytes.fromhex("41")          # 65 -> 'T'
    P2SH_VERBYTES = (bytes.fromhex("80"),)       # 128 -> 't'
    WIF_BYTE = bytes.fromhex("ef")               # 239 -> 'c'
    XPUB_VERBYTES = bytes.fromhex("043587cf")
    XPRV_VERBYTES = bytes.fromhex("04358394")
    GENESIS_HASH = ("ce81c20a59a9586946d46177317658575"
                    "b9d1c1fc07912b5488ab76202f59bcb")
    TX_COUNT = 1
    TX_COUNT_HEIGHT = 1
    TX_PER_BLOCK = 2
    PEERS = []
'''


def main():
    import io
    import sys

    path = sys.argv[1] if len(sys.argv) > 1 \
        else "/opt/electrumx/src/electrumx/lib/coins.py"

    body = io.open(path, encoding="utf-8").read()
    if "class WAMCoin(" in body:
        print("  the WAM classes are already present in %s" % path)
        return 0

    io.open(path, "a", encoding="utf-8").write(WAM_CLASSES)
    print("  appended the WAM classes to %s" % path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

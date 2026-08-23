# The founder's own node and miner, inside WSL

These are the units running on the founder's laptop. They are here so the
setup is reproducible and so the reasoning survives, not because anyone else
needs to install them.

## Why they exist at all

The node kept coming back on the wrong version. Windows restarts, WSL stops,
and the node is started again by pressing the up arrow -- which replays a
command written weeks earlier, pointing at an old build tree and carrying
`-fallbackfee=0.0001`, a workaround for a defect v0.1.4 fixed properly. On
2026-08-22 the network showed four nodes on 0.1.4 and this one on 0.1.3,
hours after it had been updated and verified.

## Why the paths carry no version

The first version of `wam-node.service` named the release directly:

    ExecStart=/home/grgo/wam-v0.1.4/wam-coin-v0.1.4/bin/wamd

which means every upgrade edits a systemd unit, and forgetting to edit it
means running the old binary while believing otherwise -- the same failure
in a new place. They now point at `~/wam-current-bin/`, a directory of
symlinks. Upgrading is: unpack the release, move the symlinks, restart. The
unit never changes again.

## What else was on that machine

Six more units at the **user** level -- `systemctl --user`, which is a
different list from `systemctl` and was not checked when these were
installed. A regtest node, a testnet node crash-looping against a port the
real node held, a second miner submitting under the same worker name, a
dashboard, and two failed pools. All leftovers from a local `install.sh`
test, all fighting the units above.

They are disabled, not deleted, with copies in `~/wam-disabled-units/`.

## Operating them

    sudo systemctl status wam-node wam-miner
    journalctl -u wam-node -f
    sudo systemctl stop wam-miner        # to free the CPU

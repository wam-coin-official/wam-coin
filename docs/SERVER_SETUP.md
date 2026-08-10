# Bringing up a WAM server

From a fresh Ubuntu box to a running node, pool, explorer and bot. Written to
be followed in order on launch day by someone who has not read the rest of this
repository.

Tested against Ubuntu 22.04 and 24.04.

---

## Before you start

**The provider's welcome email contains your root password in plain text.**
Change it and switch to SSH keys before you do anything else. That email sits in
a mailbox for ever, and mailboxes get breached.

```bash
# from YOUR computer, not the server
ssh-copy-id root@<server ip>
ssh root@<server ip>          # confirm this works without a password
passwd                        # then change the emailed password anyway
```

Do not skip the confirmation step. Everything below assumes you can get back in.

---

## 1. A user that is not root

Services should not run as root. If the pool is ever compromised, the blast
radius should be one account, not the machine.

```bash
adduser --disabled-password --gecos "" wam
usermod -aG sudo wam
rsync --archive --chown=wam:wam ~/.ssh /home/wam
```

Log out and back in as `wam`. Everything after this is done as that user.

---

## 2. Harden the machine

```bash
git clone https://github.com/wam-coin-official/wam-coin.git
cd wam-coin
sudo bash scripts/harden_server.sh --network testnet
```

This sets up a firewall, fail2ban, automatic security updates, and turns off
SSH password logins — but only if it can see that a key is already installed.
If it cannot, it says so and leaves SSH alone rather than locking you out.

Two rules in that firewall matter more than the rest:

| port | rule | why |
|---|---|---|
| 19556 / 9556 | **denied** | the RPC port is the wallet |
| 6379 | **denied** | Redis is every miner's balance |

Both listen on localhost anyway. The firewall rule is the second lock, for the
day somebody changes a bind address and does not think about it.

**Open a second terminal and confirm you can still log in before closing the
first one.** The script prints the single command that undoes the SSH change.

---

## 3. Build and install

```bash
./install.sh --network testnet
```

Twenty to forty minutes, mostly compiling. It builds the node, runs the
consensus unit tests, installs the binaries and systemd units, builds the
RandomX addon for the pool, runs the pool test suite, and generates a Redis
password.

If the unit tests fail, stop. A node that cannot agree with itself about the
money supply should not be on a network.

---

## 4. Make the node reachable

A node that does not accept connections is not a seed node. The installed unit
has `-listen=0`, which is right for a laptop and wrong here:

```bash
sudo sed -i 's/-listen=0/-listen=1/' /etc/systemd/system/wamd.service
sudo systemctl daemon-reload
sudo systemctl restart wamd
```

Confirm from *another* machine — from this one it will always look fine:

```bash
nc -vz <server ip> 19555
```

---

## 5. Point DNS at it

At the registrar, for each seed:

```
seed1.wamcoin.org.   A   <server ip>
```

Then confirm the world agrees, not just your machine:

```bash
dig +short seed1.wamcoin.org @8.8.8.8
```

DNS takes minutes to hours to spread. Until `dig` against a public resolver
returns the address, new nodes cannot find you.

---

## 6. Certificates for the dashboards

Only after DNS resolves:

```bash
sudo apt-get install -y certbot
sudo certbot certonly --standalone -d explorer.wamcoin.org
```

Then put the paths into `explorer/config.json` and restart it.

---

## 7. Check what you actually exposed

The last step, and the one people skip. **Run it from somewhere else** — a
scan from the server itself tests nothing.

```bash
# from your laptop
nmap -Pn -p 22,80,443,3333,3334,6379,9555,9556,19555,19556 <server ip>
```

You want to see:

| port | expected |
|---|---|
| 22, 80, 443, 3333, 3334, 19555 | open |
| **6379, 19556, 9556** | **filtered or closed** |

If Redis or the RPC port is open, stop and fix it before the machine holds
anything. Those two are how pools lose their miners' money.

---

## Keeping it alive

```bash
systemctl --user status wamd wam-pool wam-dashboard wam-telegram
journalctl -u wamd -f
```

The Telegram bot announces a stalled chain within the hour, which means you
hear about an outage from the same place everyone else does. That is the right
way round: an operator who only learns of problems from complaints is always
last to know.

---

## What this machine must never hold

The founder key. Not a copy, not a backup, not "temporarily while I move it".

This box is on the internet, accepts connections from strangers, and runs
network-facing code written by us. Treat everything on it as spendable by
whoever takes it, and keep the pool's hot wallet small enough that losing it
would be an incident rather than a catastrophe.

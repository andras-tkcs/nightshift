# Installing and hardening ns-main

This page builds ns-main, a plain hardened Ubuntu server, before Nightshift is put on it (phase 2). You do it once, and again only if you rebuild the server. Do [accounts.md](accounts.md) first. Replace values in `<angle brackets>`. Then go on with [setup.md](setup.md).

## What ns-main is

| | |
|---|---|
| Hetzner project | `nightshift`, firewall `ns-fw`, name `ns-main` |
| Machine | Hetzner Cloud vServer in fsn1 (Falkenstein), 8 vCPU (Intel Xeon Skylake), 16 GB RAM (15.2 GB usable), 4 GB swap, 80 GB disk (75 GB file system). Read from the machine on 2026-10-06 (`nproc`, `lscpu`, `free -m`, `lsblk`, `df -h /`, `/sys/class/dmi/id`, the metadata service). The server type is not known from the machine: the metadata service does not report it, and the 80 GB disk is neither a CX23 (40 GB) nor a CX43 (160 GB) disk, so it was most likely rescaled with CPU and RAM only from a type with an 80 GB disk |
| System | Ubuntu 24.04 |
| Agent user | `ns`, with no sudo on purpose |
| Workers | `max_workers` is 4 (`config.yaml`; the code default is 2, which fits the 4 GB minimum) |
| Conductors | `max_runs` is 3 (`config.yaml`; code default 2): further runs wait as `queued` until a conductor ends (`ns dequeue`) |
| Reachable | only over Tailscale (name `ns-main`, tag `tag:ns-main`) |

## Do this first

1. Create the server (below).
2. Run the blocks below in order. Run each on its own; the ones marked interactive wait for you.
3. Run the check block at the end.

## Create ns-main

In the Hetzner console, project `nightshift`, Add server: Falkenstein, Ubuntu 24.04, IPv4 and IPv6, your Blink key, firewall `ns-fw`, Backups on, name `ns-main`. Pick a type with 2 vCPU and 4 GB RAM or more (the minimum, R-ENV-5). ns-main now runs with 8 vCPU and 16 GB.

## Base system, swap and the agent user

As root over SSH (`ssh root@<ns-main-ipv4>` from Blink):

```bash
apt update && apt -y full-upgrade
apt -y install git tmux mosh curl jq ripgrep unzip build-essential parallel \
  python3 python3-venv python3-pip pipx ufw unattended-upgrades
timedatectl set-timezone Europe/Budapest
```

4 GB of swap as a safety net. It was sized for the original 4 GB machine and is kept on the 16 GB one:

```bash
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

The agent user, without sudo, and key-only SSH:

```bash
adduser --disabled-password --gecos "" ns
install -d -m 700 -o ns -g ns /home/ns/.ssh
install -m 600 -o ns -g ns /root/.ssh/authorized_keys /home/ns/.ssh/
loginctl enable-linger ns
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl reload ssh
```

## Tailscale, then close the public door

The access policy from [accounts.md](accounts.md) is already in place, so the server gets its tag right away. As root:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --ssh --hostname ns-main --advertise-tags=tag:ns-main
```

Open the printed URL on the iPad. Then disconnect and reconnect over Tailscale (`ssh root@ns-main`) before the next block: enabling the firewall from the public connection would cut you off.

## Firewall (ufw)

Allow only the tailnet. As root, over Tailscale:

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw allow 41641/udp
ufw --force enable
```

Test from Blink with `mosh ns@ns-main`. Only then, in the Hetzner console, delete the TCP 22 rule from `ns-fw`.

## GitHub CLI (gh)

As root:

```bash
install -d -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt update && apt -y install gh
```

## Claude Code and the GitHub login

As `ns` (connect with `mosh ns@ns-main`). Run each block on its own.

```bash
curl -fsSL https://claude.ai/install.sh | bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
claude --version
```

Interactive: open the URL on the iPad, paste the code back, then `/exit`:

```bash
claude
```

Interactive: GitHub.com, HTTPS, paste the agent token for `andras-tkcs` from [accounts.md](accounts.md):

```bash
gh auth login
```

```bash
gh auth setup-git
git config --global user.name  "Nightshift (ns-main)"
git config --global user.email "$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')"
git config --global user.email
```

The last line prints the noreply address, so you can check it. The Claude login is valid for a long time but does expire. Claude Code warns three days ahead; renew it with `/login` (see [operations.md](operations.md)).

## tmux and maintenance basics

As root: security updates on, automatic reboots off, logs capped at 500 MB.

```bash
cat > /etc/apt/apt.conf.d/52nightshift <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=500M\n' > /etc/systemd/journald.conf.d/size.conf
systemctl restart systemd-journald
```

As `ns`: the tmux settings, the folders, and session transcripts kept for 30 days:

```bash
cat > ~/.tmux.conf <<'EOF'
set -g mouse on
set -g history-limit 100000
set -g default-terminal "tmux-256color"
set -g status-right "#H  %H:%M"
EOF
mkdir -p ~/.claude ~/Coding/worktrees
[ -f ~/.claude/settings.json ] || echo '{}' > ~/.claude/settings.json
jq '.cleanupPeriodDays = 30' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
```

## Check

As `ns`:

```bash
claude doctor
gh auth status
tailscale status
sudo -n true 2>/dev/null && echo "WARNING: ns has sudo" || echo "ok: ns has no sudo"
```

Done when:

- the four checks above pass,
- `mosh ns@ns-main` works from Blink over Tailscale,
- TCP 22 is gone from the Hetzner firewall `ns-fw`.

After [setup.md](setup.md) is done, `ns doctor` repeats and extends these checks.

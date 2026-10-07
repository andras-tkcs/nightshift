# Setting up Nightshift on ns-main

This page turns a hardened phase-2 server into a Nightshift runtime. One script, `bootstrap.sh`, does it; every step below also lists the manual commands, for fixing things by hand. Replace values in `<angle brackets>`.

You need: root on ns-main, Tailscale connected with HTTPS certificates enabled, a Cloudflare account with a domain, the Hetzner `nightshift-lab` project token, and a release tag (`v*`) on the Nightshift repository (see [development.md](development.md), "Releasing"). The script installs the release, not your dev clone (ADR 0007).

## Do this first

1. Create the Cloudflare tunnel (below) and copy its token. Paste it only into `bootstrap.sh`, never into a chat or a file in a repo.
2. See what the script would do, as any user:

   ```bash
   ~ns/Coding/nightshift/bin/bootstrap.sh --check
   ```

3. Run it as root:

   ```bash
   sudo ~ns/Coding/nightshift/bin/bootstrap.sh
   ```

4. Add the Cloudflare routes, do the SilverBullet first run, and optionally set up the browser terminal (option B), all below.
5. Run `ns doctor` as `ns`; step 11 already did, so this is only for later.

`--check` prints one line per step: `[n/11] <name>: ok`, `would change: <what>`, `needs you: <what>` or `unknown: <what>`. It exits 0 when everything is ok, else 1, and changes nothing. A real run needs root (otherwise exit 2, `run as root, or use --check`). Secrets are read with `read -rs`: they are never echoed, logged or put on a command line.

### Cloudflare: create the tunnel

1. Cloudflare dashboard, Networking, Tunnels, Create a tunnel (older layouts: Zero Trust, Networks, Tunnels). Choose Cloudflared.
2. Name it `ns-main`, Create tunnel.
3. Choose Debian, 64-bit. Do not run the install commands; `bootstrap.sh` installs cloudflared. Copy only the token, the long string at the end of the `cloudflared service install ...` line.
4. Leave the page open, run `bootstrap.sh` and paste the token when asked. The page then shows the connector as Connected.

### Cloudflare: routes

Tunnel `ns-main`, Routes, Add route, Published application:

- `ns-desk.<domain>` to `http://127.0.0.1:3000` (SilverBullet)
- `ns-view.<domain>` to `http://127.0.0.1:8080` (Caddy's local HTML listener)
- only for the browser terminal: `ns-ssh.<domain>` to `ssh://127.0.0.1:22`

Cloudflare creates the DNS records. Never add a record that points at ns-main's IP address. Use one level under your domain (`ns-desk.`, not `desk.ns.`), because the free certificate covers `*.<domain>` only. The Access applications and the "only me" policy belong to the account setup.

### SilverBullet first run

1. Open `https://ns-main.<tailnet>.ts.net` on the iPad (or `https://ns-desk.<domain>` through the tunnel).
2. The wizard asks for an admin account, then for the first space: name it `nightshift` and point its folder at `/srv/ns-space`.
3. In Space settings add `ns-desk.<domain>` as an extra hostname.
4. Check the HTML side: `https://ns-main.<tailnet>.ts.net:8443` shows the folder listing.

Upgrading SilverBullet later:

```bash
~/opt/silverbullet/silverbullet upgrade
systemctl --user restart silverbullet
```

### Option B: the browser terminal

Skip this unless you want a terminal in the browser. In Cloudflare, turn on browser rendering (SSH) for the `ns-ssh.` route, then Zero Trust, Access controls, Service credentials, SSH, Add a certificate, select the `Nightshift terminal` application and copy the public key. Step 5 asks for it, and for the principal (the part of your email before the `@`).

## The eleven steps

`bootstrap.sh` is safe to run again: it only changes what is missing. Rerun it after fixing anything that said `needs you`.

### 1. Caddy and desk certificates

Caddy from its apt repository, `TS_PERMIT_CERT_UID=caddy`, and `/etc/caddy/Caddyfile` rendered from `templates/caddy/Caddyfile.tmpl`: the desk on `:443` to `127.0.0.1:3000`, the HTML view on `:8443`, ntfy on `:8444` to `127.0.0.1:2586`, and `http://127.0.0.1:8080` for the tunnel. Needs Tailscale connected (otherwise `needs you: tailscale is not connected`). The manual way:

```bash
apt -y install debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt update && apt -y install caddy
echo 'TS_PERMIT_CERT_UID=caddy' >> /etc/default/tailscaled
systemctl restart tailscaled
sed "s/@TS_HOST@/$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')/g" \
  ~ns/Coding/nightshift/templates/caddy/Caddyfile.tmpl > /etc/caddy/Caddyfile
systemctl reload caddy
```

The explicit `get_certificate tailscale` matters: recent Caddy versions otherwise try Let's Encrypt for `.ts.net` names and fail.

### 2. Desk folder /srv/ns-space

The folder the desk is served from: owner `ns`, group `caddy`, mode 2750.

```bash
install -d -o ns -g caddy -m 2750 /srv/ns-space
```

### 3. SilverBullet

The SilverBullet binary in `~ns/opt/silverbullet/`, data in `~ns/sb-data`, a systemd user service on `127.0.0.1:3000` from `templates/systemd/silverbullet.service`, enabled, and lingering switched on for `ns` so the service runs without a login. As `ns`:

```bash
mkdir -p ~/opt/silverbullet ~/sb-data ~/.config/systemd/user
cd ~/opt/silverbullet
curl -fsSLO https://github.com/silverbulletmd/silverbullet/releases/latest/download/silverbullet-server-linux-x86_64.zip
unzip -o silverbullet-server-linux-x86_64.zip && chmod +x silverbullet
cp ~/Coding/nightshift/templates/systemd/silverbullet.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now silverbullet
```

As root: `loginctl enable-linger ns`.

### 4. cloudflared tunnel

The cloudflared `.deb` from the GitHub release, then the tunnel token (asked, not shown) and `cloudflared service install <token>`. Until the service exists, `--check` says `needs you: tunnel token`. Run the script in a terminal for this step. The manual way:

```bash
curl -fsSL -o /tmp/cloudflared.deb \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
apt -y install /tmp/cloudflared.deb
cloudflared service install <tunnel-token>
```

### 5. Cloudflare SSH CA (optional)

If `/etc/ssh/cloudflare_ca.pub` exists the step is ok. Otherwise a real run asks `Set up the browser terminal (option B)? [y/N]`; answer `y` to give it the CA public key and the principal. It writes the three files, checks `sshd -t` and only then reloads. `--check` without the file says `ok (not configured)`. The manual way, as root:

```bash
echo '<public key of the Cloudflare SSH CA>' > /etc/ssh/cloudflare_ca.pub
mkdir -p /etc/ssh/principals
echo '<the part of your email before @>' > /etc/ssh/principals/ns
cat > /etc/ssh/sshd_config.d/cloudflare.conf <<'EOF'
TrustedUserCAKeys /etc/ssh/cloudflare_ca.pub
Match User ns
    AuthorizedPrincipalsFile /etc/ssh/principals/%u
EOF
sshd -t && systemctl reload ssh
```

### 6. hcloud CLI

The Hetzner CLI in `~ns/.local/bin/hcloud` and the context `nightshift-lab` for the lab project (Build B uses it). The script asks for the lab project token (not shown) and hands it to `hcloud` through the environment, never on a command line. The manual way, as `ns`:

```bash
curl -fsSL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz \
  | tar xz -C ~/.local/bin hcloud
hcloud context create nightshift-lab          # interactive: paste the lab token
```

### 7. ntfy topic and desk settings

`~ns/.config/ns/env` (mode 600, owner `ns`) gets `NS_NTFY_TOPIC` (generated as `ns-<16 hex digits>` when absent), `NS_DESK_URL` (asked, for example `https://ns-desk.<domain>`) and optionally `NS_HEALTHCHECK_URL` (asked once, not shown). Optional lines you add by hand: `NS_NTFY_URL` (your own ntfy, `https://<host>[:port]`; default `https://ntfy.sh`) and `NS_NTFY_PRIORITY` (ntfy priority for every notification: `min`, `low`, `default`, `high`, `max` or `1` to `5`); see `ns-notify` in usage.md. The script prints the topic: subscribe to it in the ntfy app. An ntfy.sh topic is public to anyone who knows the name, so messages only say "gate reached, run 123", never code or findings. The manual way, as `ns`:

```bash
mkdir -p ~/.config/ns && touch ~/.config/ns/env && chmod 600 ~/.config/ns/env
echo "export NS_NTFY_TOPIC='ns-$(openssl rand -hex 8)'" >> ~/.config/ns/env
echo "export NS_DESK_URL='https://ns-desk.<domain>'" >> ~/.config/ns/env
. ~/.config/ns/env && echo "$NS_NTFY_TOPIC"
curl -d "ns-main is alive" ntfy.sh/$NS_NTFY_TOPIC
```

### 8. Release install under /opt/nightshift

The newest `v*` tag of the Nightshift repository is cloned to `/opt/nightshift/<tag>` (owned by root, not writable by `ns`), `/opt/nightshift/current` points at it, and `ns`, `ns-conductor`, `ns-notify`, `ns-gh`, `ns-ledger` and `ns-launch` in `/usr/local/bin` link to `/opt/nightshift/current/bin/<name>`. Work in `~ns/Coding/nightshift` therefore never affects the running version, and agents running as `ns` cannot modify it. With no tag yet the step says `needs you: no release tag yet`; the owner tags the release (ADR 0007), then rerun. The manual way, as root:

```bash
tag=$(git ls-remote --tags --refs https://github.com/andras-tkcs/nightshift 'v*' | sed 's|.*refs/tags/||' | sort -V | tail -n 1)
git clone --quiet --branch "$tag" --depth 1 https://github.com/andras-tkcs/nightshift /opt/nightshift/$tag
chown -R root:root /opt/nightshift/$tag && chmod -R go-w /opt/nightshift/$tag
ln -sfn "$tag" /opt/nightshift/current
for n in ns ns-conductor ns-notify ns-gh ns-ledger ns-launch; do
  ln -sfn /opt/nightshift/current/bin/$n /usr/local/bin/$n
done
```

### 9. Plugin marketplace and plugins

As `ns`, the marketplace `nightshift` is added as `<owner/repo>#<tag>`, pinned to the installed release, and `ns@nightshift` and `ns-python@nightshift` are installed at user scope. Projects never reference them, so a project's repo stays free of Nightshift settings. The script remembers the pin in `~ns/.config/ns/release-pin`; when the tag changes it removes the marketplace and adds it again. The manual way, as `ns`:

```bash
claude plugin marketplace add andras-tkcs/nightshift#<tag>
claude plugin install ns@nightshift --scope user
claude plugin install ns-python@nightshift --scope user
claude plugin list
```

### 10. ns-gc and ns-health timers and Remote Control

The units `ns-gc.*` and `ns-health.*` from `templates/systemd/` go to `~ns/.config/systemd/user/` and the timers are enabled (daily housekeeping at 04:00; `ns check` every 5 minutes). When a project is registered, the Remote Control session (tmux `rc`) is started as `ns up` does; before that the step says `ok (no project yet; ns up starts it)`. The manual way, as `ns`:

```bash
cp ~/Coding/nightshift/templates/systemd/ns-gc.* ~/Coding/nightshift/templates/systemd/ns-health.* ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now ns-gc.timer ns-health.timer
ns up
```

### 11. ns doctor

The script ends by running `ns doctor` as `ns` (with `~/.config/ns/env` loaded), shows its output and reports its status: `ok (ns doctor passed)` or `needs you: ns doctor reported problems`. In a real run this step always runs. What each check means is in [usage.md](usage.md). The manual way:

```bash
runuser -l ns -c '. ~/.config/ns/env; ns doctor'
```

## Order matters for ns-gh

`ns-gh apply` for a project runs after that project's onboarding PR is merged, because `ns-gh` reads `.claude/ns-github.env` from the project's default branch. Nightshift's own repository carries `.claude/ns-github.env` from the start, so it can go first. If you ran `ns-gh apply` too early, run it again after the merge.

## Upgrading

To move to a newer release, or back to an older one, as root:

```bash
sudo /opt/nightshift/current/bin/bootstrap.sh --upgrade v0.1.1
```

`--upgrade <tag>` runs only steps 8, 9 and 10: it clones that tag to `/opt/nightshift/<tag>` if missing, repoints `/opt/nightshift/current`, re-pins the marketplace and plugins to the tag, and installs and enables the `ns-gc` and `ns-health` timers with the units of that release. Earlier releases stay in place, so rollback is `--upgrade <old tag>`. A tag that does not exist exits 1 and changes nothing. Your dev clone `~ns/Coding/nightshift` is never touched.

## While runs are live

Every mode that changes the install (a plain run, `--upgrade`, any step) first checks for live jobs: a run's tmux session, its conductor process (`~ns/.config/ns/logs/<id>/conductor.pid`) or a worker (`~ns/.config/ns/workers/*.pid`). If there is one it refuses with exit 1 before step 1 and lists each as `id  state  release  pid`; `--force` proceeds anyway, in every mode. A run that is `running` in its ledger with nothing alive is a warning (`looks dead: ns kill <id> or ns stop <id>`), and runs at a gate, queued or parked are listed as information; neither blocks. `--check` changes nothing and reports the same lists. While it runs, the script holds `/opt/nightshift/.upgrade.lock`; `ns new`, `ns resume`, `ns dequeue` and `ns approve` refuse to start a conductor until it is removed at the end. Before listing the jobs it waits up to 130 s (`NS_BS_QUEUE_WAIT`) for the queue lock `~ns/.config/ns/queue.lock`, so a conductor start already in flight finishes first; a queue lock that stays busy refuses unless `--force`. A second `bootstrap.sh` refuses while the first holds the lock. A lock left behind with no `bootstrap.sh` running is removed with `sudo rm /opt/nightshift/.upgrade.lock`. Plugins are updated only by step 9 of the script, behind this check; see [operations.md](operations.md#updates).

Check afterwards:

```bash
ns doctor
bootstrap.sh --check
```

## Running it again

`bootstrap.sh` can be rerun at any time, for example after a failed step, but not while a job is live (see above). `--check` always shows what it would do first.

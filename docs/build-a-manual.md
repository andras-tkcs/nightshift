# Build A: what you do by hand

Companion to [`build-a-plan.md`](build-a-plan.md). Everything else in Build A runs unattended. Tick the boxes as you go; GitHub renders them in the PR.

Never paste a token into a chat, a PR, an issue or a file in a repo. Each step below says exactly where a secret goes.

## Before implementation

### mb1. Install bats and shellcheck (about 3 minutes)

Every phase runs `tests/lint` and `bats tests/bats`. The `ns` user has no sudo, so this needs root.

- [ ] 1. From the iPad (Blink) or a browser terminal, connect as root: `ssh root@ns-main`.
- [ ] 2. Install both tools:
  ```bash
  apt-get update && apt-get install -y bats shellcheck
  ```
- [ ] 3. Log out, then connect as ns (`mosh ns@ns-main`) and check:
  ```bash
  bats --version && shellcheck --version
  ```

**Done when** both commands print a version as `ns`. Then start Build A with `/implement-local docs/build-a-plan.md` on branch `plan/build-a`.

## After implementation (Review 1)

These are phase 4 of the architecture page. Do them in this order. The repo docs linked below exist on `main` once you have merged the PR.

### ma1. Review and merge the PR (about 45 minutes)

- [ ] 1. Open the PR at <https://github.com/andras-tkcs/nightshift/pulls> (title starts with `Build A`).
- [ ] 2. Read the final review section and the open items. CI must be green.
- [ ] 3. Open the five sandbox PRs linked from `tests/e2e/results.md` (<https://github.com/andras-tkcs/nightshift-sandbox/pulls>). Each one is a real run: skim the diff and, for t2, t3 and resume, the handoff report linked in the PR body.
- [ ] 4. Merge the PR with a merge commit (not squash).

**Report back:** a comment on the PR, `Reviewed and merged: pass`, or what you would change (that becomes `docs/review-1.md` input).

### ma2. Tag v0.1.0 (about 2 minutes)

`bootstrap.sh` installs the plugins from the newest `v*` tag (ADR 0007), so tag before you bootstrap.

- [ ] 1. As ns on ns-main:
  ```bash
  cd ~/Coding/nightshift
  git fetch origin main
  git tag -a v0.1.0 -m "Nightshift v0.1.0" origin/main
  git push origin v0.1.0
  ```
- [ ] 2. Check that <https://github.com/andras-tkcs/nightshift/tags> shows `v0.1.0`.

### ma3. Create the Cloudflare tunnel (about 5 minutes)

Do this right before ma4; bootstrap asks for the token.

- [ ] 1. Open <https://one.dash.cloudflare.com/> → your account → **Networks → Tunnels** (newer layout: **Networking → Tunnels** on <https://dash.cloudflare.com/>) → **Create a tunnel** → type **Cloudflared**.
- [ ] 2. Name it `ns-main` → **Create tunnel**.
- [ ] 3. Pick **Debian, 64-bit**. Do not run the commands shown. Copy only the long token at the end of the `cloudflared service install …` line. Keep the page open.

The token goes only into bootstrap's hidden prompt in ma4. Nowhere else.

### ma4. Run bootstrap.sh (about 20 minutes)

What each step does: [docs/setup.md](https://github.com/andras-tkcs/nightshift/blob/main/docs/setup.md).

- [ ] 1. As ns: `cd ~/Coding/nightshift && git switch main && git pull` (this dev clone only supplies `bootstrap.sh`; the running Nightshift is installed from the tag into `/opt/nightshift/v0.1.0` and is not affected by later work in the clone).
- [ ] 2. As root, dry run first; it changes nothing:
  ```bash
  ~ns/Coding/nightshift/bin/bootstrap.sh --check
  ```
  You should see eleven `[n/11]` lines, most of them `would change`.
- [ ] 3. As root, the real run:
  ```bash
  ~ns/Coding/nightshift/bin/bootstrap.sh
  ```
  It asks, in this order: the tunnel token (hidden, paste from ma3), whether you want the browser terminal (option B; answer `n` unless the work network blocks Tailscale), the Hetzner lab token (hidden; Hetzner console → project `nightshift-lab` → Security → API tokens), the desk URL (`https://ns-desk.<your domain>`), and an optional healthchecks.io URL (hidden).
- [ ] 4. Note the ntfy topic it prints and subscribe to it in the ntfy app on the phone.
- [ ] 5. Back on the Cloudflare tunnel page from ma3, the connector shows **Connected** → **Continue**.

**Report back:** the last block of bootstrap's output (the `ns doctor` lines; they contain no secrets).

### ma5. Cloudflare routes, SilverBullet, desk test (about 15 minutes)

- [ ] 1. Tunnel `ns-main` → **Routes → Add route → Published application**: subdomain `ns-desk`, your domain, service `http://127.0.0.1:3000`. Again for `ns-view` → `http://127.0.0.1:8080`. Only with option B: `ns-ssh` → `ssh://127.0.0.1:22`.
- [ ] 2. The tunnel shows **Healthy**, and your domain's DNS records show one proxied CNAME per route.
- [ ] 3. On the iPad (Tailscale on) open `https://ns-main.<tailnet>.ts.net`. SilverBullet's wizard asks for an admin account, then a space: name it `nightshift`, folder `/srv/ns-space`.
- [ ] 4. In SilverBullet → **Space settings**, add `ns-desk.<your domain>` as an extra hostname.
- [ ] 5. On the work laptop, in a private window, open `https://ns-desk.<your domain>`. You must see Google sign-in first, then SilverBullet's own login. **If SilverBullet appears without the Google step, stop**: the Access application does not match the route. Fix it under Zero Trust → Access controls → Applications.
- [ ] 6. `https://ns-view.<your domain>` shows the folder listing after Google sign-in.

### ma6. ns-gh for the two Nightshift repos (about 10 minutes)

PrivacyFence gets its turn in ma7, after its onboarding PR is merged: `ns-gh` reads `.claude/ns-github.env` from the default branch.

- [ ] 1. Create one fine-grained token at <https://github.com/settings/personal-access-tokens/new> with **7 days** expiry, resource owner **you** (repos `nightshift`, `nightshift-sandbox`), **Administration, Environments, Issues: Read and write**.
- [ ] 2. As root. The token lives only in the shell variable:
  ```bash
  read -rsp "admin token (you): " GH_TOKEN; export GH_TOKEN; echo
  ns-gh audit andras-tkcs/nightshift      # read the table
  ns-gh apply andras-tkcs/nightshift
  ns-gh apply andras-tkcs/nightshift-sandbox
  unset GH_TOKEN
  ```
- [ ] 3. Delete the token at <https://github.com/settings/personal-access-tokens>.

**Report back:** `ns-gh audit andras-tkcs/nightshift` ends with `All settings match.`

### ma7. Add PrivacyFence (about 45 minutes)

Steps: [docs/projects.md](https://github.com/andras-tkcs/nightshift/blob/main/docs/projects.md). Onboarding only adds three files to PrivacyFence (profile, `.claude/ns-github.env`, a domain-skill draft). It leaves `CLAUDE.md` and the old `/make-plan`, `/implement`, `/dod` alone.

- [ ] 1. Create the PrivacyFence agent token at <https://github.com/settings/personal-access-tokens/new>: resource owner **privacyfence**, only `privacyfence/privacyfence`, **Contents, Issues, Pull requests, Actions: Read and write**, **Commit statuses: Read**, 90 days. No Workflows, Administration, Secrets or Environments.
- [ ] 2. As ns, store it (paste, then Ctrl-D):
  ```bash
  install -d -m 700 ~/.config/ns/tokens
  (umask 077; cat > ~/.config/ns/tokens/privacyfence)
  ```
- [ ] 3. `ns project add privacyfence/privacyfence --prefix pf`. It adopts `~/Coding/privacyfence` if that clone exists, otherwise clones it, and starts the onboarding run `pf-onboard`.
- [ ] 4. When ntfy says gate 1 (10–20 minutes), open the desk folder `privacyfence/runs/pf-onboard/`. Check the profile first, especially lines marked `# guess:` (commands, stacks and paths, risk zones, platform paths). Edit in place.
- [ ] 5. `ns approve pf-onboard`: read the diff, answer `y`. It opens a PR from branch `nightshift/onboard` on PrivacyFence.
- [ ] 6. Review and merge that PR on GitHub. Until you do, `ns new pf-…` refuses to start.
- [ ] 7. Now PrivacyFence's GitHub settings. Create a token like ma6 but with resource owner **privacyfence** (repo `privacyfence`), then as root:
  ```bash
  read -rsp "admin token (privacyfence): " GH_TOKEN; export GH_TOKEN; echo
  ns-gh audit privacyfence/privacyfence
  ns-gh apply privacyfence/privacyfence
  unset GH_TOKEN
  ```
- [ ] 8. Delete that admin token on GitHub.

### ma8. ns doctor and a test notification (about 5 minutes)

- [ ] 1. As ns: `ns doctor`. Every line is `ok` or `warn`; no `FAIL`.
- [ ] 2. `ns-notify "ns-main test"`. The phone shows it.

### ma9. Review 1: real work (one evening plus the next)

- [ ] 1. Before bed, pick one real bug issue and one small feature issue on PrivacyFence and start them: `ns new pf-<issue>` (answer the tier question; expect T1 and T2).
- [ ] 2. Approve the T2's plan at gate 1 on the desk, then `ns approve pf-<issue>`.
- [ ] 3. Next evening, read both handoff reports and PRs.
- [ ] 4. Judge the docs as a newcomer: could you have done ma3–ma8 from `docs/setup.md` and `docs/projects.md` alone?
- [ ] 5. Write what you want changed into `docs/review-1.md` on the desk. It is Build B's first input.

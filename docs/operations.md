# Operating Nightshift

Reboots, cleanup, updates, renewals, backup and restore, troubleshooting, and shutting everything down. The daily commands are in [usage.md](usage.md). Commands run as user `ns` on ns-main unless a block says root.

## Do this first: a calendar

| When | What | How |
|---|---|---|
| Daily, automatic | Cleanup, disk check, "reboot required" check | the `ns gc` timer; one ntfy line |
| When ntfy says so | Reboot | `ns drain`, reboot, `ns up`, `ns resume --all` (below) |
| Weekly | Glance at the desk index and `ns ls`; approve waiting QA jobs | iPad or the GitHub app |
| Monthly | The checklist at the end of this page | |
| Every 90 days | Renew the agent tokens | below |
| When Claude warns | Renew the Claude login | below |
| Each Nightshift release | Install it, keep a way back | below |
| Twice a year | Restore drill | below |

## Reboots

A reboot never loses a run, because every run's state is in its ledger in git. It can lose the step that was in progress, so drain first when you can. Security updates install on their own but never reboot on their own; `ns gc` sends "reboot required" to your phone when an update needs one.

Before a planned reboot, as `ns`:

```bash
ns drain
ns ls
```

`ns drain` asks every running run to stop at its next checkpoint and waits until none is running (default limit 1800 seconds, then it prints `still running: <ids>` and exits 1). `ns ls` should show every run as `parked`. Runs waiting at a gate are left alone. Then, as root:

```bash
reboot
```

An unplanned reboot (Hetzner maintenance, a crash) is the same, minus the drain: each run loses at most its current step.

After the reboot, as `ns` (`mosh ns@ns-main` from Blink):

```bash
ns up
ns ls
ns resume --all
```

`ns up` runs `ns doctor`, restarts the Remote Control session (tmux `rc`) and lists parked runs. `ns resume --all` restarts every parked, stopped or crashed run; use `ns resume <id>` for one. Tailscale, Caddy, cloudflared, SilverBullet and the `ns gc` timer come back on their own. Claude sessions, Nightshift runs and Remote Control are started by you, on purpose, so you see the state before agents spend usage again. A plain interactive Claude session comes back with `claude --continue` in its folder.

## Cleanup: what `ns gc` drops

`ns gc` runs daily at 04:00 from a systemd timer, and its monthly tasks run on the 1st. To see what it would do without doing it:

```bash
ns gc --dry-run
```

It ends with one ntfy line such as "freed 3.1 GB, 1 item(s) need you, reboot required, disk 85%", and it warns when the disk is 80 % full or more.

What piles up, and what drops it:

| What | Where | Dropped when | By |
|---|---|---|---|
| Run and phase worktrees, with their `.venv` and build output | `~/Coding/worktrees/` | The run is `done` and its pull request is merged or closed | `ns gc`, daily |
| Worktrees Claude made itself (Remote Control, subagents) | `<repo>/.claude/worktrees/` | Clean ones: on exit, or after 30 days. Ones with unsaved work: never; `ns gc` lists them | Claude Code, `ns gc` report |
| Local branches; remote `plan/` and phase branches | git | Same moment as the run's worktrees (`git branch -d`, so unmerged ones stay) | `ns gc`, daily |
| A finished run's tmux session | tmux | The run is archived | `ns gc`, daily |
| Review desk documents | `/srv/ns-space/<repo>/runs/<id>` | Moved to `archive/<yyyy-mm>/<id>` at the same moment; archive folders older than 90 days are deleted | `ns gc`, daily |
| pip cache and other stack targets | `~/.cache/pip` | Monthly | `ns gc`, monthly |
| Session transcripts | `~/.claude/projects/` | Older than `cleanupPeriodDays` (30) | Claude Code |
| System logs | journald | Capped at 500 MB | journald |
| Old packages and kernels | apt | Monthly, by you, as root: `apt autoremove --purge` | you |
| GitHub Actions artifacts | repo settings | After 14 days | GitHub, via `ns-gh` |

Never dropped automatically:

- anything belonging to a run that is not `done`, or whose pull request is still open,
- a worktree with uncommitted or unpushed work: `ns gc` prints `needs you: <path>: <reason>` and keeps the whole run,
- the base branch, a project's main checkout, git history, merged pull requests and ADRs,
- Hetzner backups, which rotate on their own.

When a `needs you` line appears, go to that worktree, commit and push or discard the work yourself, then `ns gc` takes the run on its next pass.

## Updates

Nightshift runs from a release under `/opt/nightshift/<tag>`, not from your dev clone. Your dev clone `~/Coding/nightshift` is never involved in an update. To install a release or go back to an older one, as root:

```bash
/opt/nightshift/current/bin/bootstrap.sh --upgrade <tag>
```

It installs `/opt/nightshift/<tag>` if missing, repoints `/opt/nightshift/current` to it, and re-pins the plugin marketplace and plugins to that tag. Earlier releases stay in place.

Rollback is the same command with the previous tag:

```bash
/opt/nightshift/current/bin/bootstrap.sh --upgrade <previous tag>
```

Check afterwards, as `ns`:

```bash
ns doctor
```

Do it between runs: `ns drain` first, then `ns resume --all` afterwards. Other updates:

- SilverBullet, as `ns`:

  ```bash
  ~/opt/silverbullet/silverbullet upgrade
  systemctl --user restart silverbullet
  ```

- Claude Code updates itself.
- Operating system security updates install on their own; reboot when told.

## Renewals

### Tokens, every 90 days

The agent tokens expire after 90 days. `ns doctor` warns 14 days ahead (a `warn` line for each token file) and fails when one has expired.

1. On GitHub: your profile, Settings, Developer settings, Fine-grained tokens, the token, Regenerate. Keep the same name, owner, repositories and permissions ([accounts.md](accounts.md)).
2. For the `andras-tkcs` token, as `ns`:

   ```bash
   gh auth login
   ```

3. For another owner's token, as `ns`, replace the one line in the file and keep mode 600:

   ```bash
   read -rs -p "token: " t; echo
   printf '%s\n' "$t" > ~/.config/ns/tokens/<owner>
   chmod 600 ~/.config/ns/tokens/<owner>
   unset t
   ```

4. Check:

   ```bash
   ns doctor
   ```

The admin tokens for `ns-gh` live 7 days and are never stored, so there is nothing to renew.

### Claude login

The login is valid for a long time but expires. Claude Code warns three days ahead. Renew it before an overnight run: in any Claude session on ns-main, type:

```
/login
```

## Backup and restore

In git, safe anywhere: code, plans, ADRs, approved desk documents, run ledgers.

Only on ns-main:

- `~/.claude` (the login, transcripts),
- `~/.config/ns` (tokens, project list, `env`),
- `~/sb-data` and `/srv/ns-space` (desk drafts not yet approved).

Hetzner's daily backups (turned on when the server was created) cover those and keep seven.

If the server is lost:

1. Create a new server and follow [server.md](server.md).
2. Run `bootstrap.sh` ([setup.md](setup.md)).
3. Re-enter the tokens ([accounts.md](accounts.md)) and log in to Claude again.
4. Register the projects again with `ns project add`, then `ns resume --all`. Runs resume from their ledgers in git.

Restore drill, twice a year: rebuild a throwaway server this way from a backup and confirm that `ns doctor` is green and `ns ls` shows your runs.

## Troubleshooting

### A run seems stuck

1. See where it is:

   ```bash
   ns ls
   ns status <id>
   ```

   `ns status` shows state, gate, step, the time budget used, each phase with its attempts, and the last five ledger events.

2. Watch it live (detach with `Ctrl-b d`; the run keeps going):

   ```bash
   ns attach <id>
   ```

3. Read the logs of the run:

   ```bash
   ls ~/.config/ns/logs/<id>/
   tail -n 50 ~/.config/ns/logs/<id>/conductor.jsonl
   ```

4. If the state is `running` but there is no tmux session (`ns doctor` warns `run <id> has no session`), the conductor died:

   ```bash
   ns resume <id>
   ```

5. To stop a run at its next checkpoint:

   ```bash
   ns stop <id>
   ```

### A run at gate 1.5

Gate 1.5 is an escalation: the run hit its time budget or three review rounds on a phase and parked itself. It put an `escalation.md` on the desk and sent an ntfy message. Read `escalation.md` at the desk, then:

1. Edit the desk documents as the escalation asks (for example give more budget or change the plan).
2. Release the gate:

   ```bash
   ns approve <id>
   ```

   `ns approve` shows a diff of your edits, asks for confirmation, commits them and restarts the run. Answering anything but `y` changes nothing.
3. Or end the run:

   ```bash
   ns stop <id>
   ```

### The server looks unhealthy

```bash
ns doctor
df -h /
free -m
```

`ns doctor` names the failing service, token, disk or setting. If `ns doctor` says auto permission mode does not work, read the "Worker permission mode" section of [security.md](security.md).

### Knowing the server is down

ntfy messages come from ns-main itself, so a dead server sends nothing. Use a free dead-man's switch such as healthchecks.io: put its ping URL into `~/.config/ns/env` as `NS_HEALTHCHECK_URL` (`export NS_HEALTHCHECK_URL='<url>'`), and `ns gc` pings it daily when it finishes without errors. A missed ping emails you.

## Monthly checklist

About 15 minutes.

```bash
ns ls --all
ns gc --dry-run
ns doctor
```

Then, as root:

```bash
apt autoremove --purge
```

And:

- Claude usage, the Hetzner bill and GitHub Actions minutes in their consoles.
- `needs you` lines from `ns gc` dealt with.
- SilverBullet upgrade (above).
- Token expiry dates in `ns doctor` are more than 14 days away.

## Shutting everything down

To remove Nightshift completely:

1. `ns drain`, then `ns stop <id>` for anything left, and let `ns gc` finish old runs.
2. Delete the Hetzner servers (and any lab snapshots) in the `nightshift` and `nightshift-lab` projects.
3. Revoke the tokens: the agent tokens and any admin token on GitHub (Developer settings), the Hetzner API tokens.
4. In Cloudflare: delete the tunnel `ns-main` and the three Access applications (`Nightshift desk`, `Nightshift reports`, and `Nightshift terminal` if you made it); delete the Google OAuth client in the Google Cloud project `nightshift-access`.
5. In Tailscale: remove the machine `ns-main` in the admin console.
6. On GitHub: the repositories `nightshift` and `nightshift-sandbox` can stay or be archived; nothing in the `privacyfence` org needs undoing except the token.

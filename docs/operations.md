# Operating Nightshift

Reboots, cleanup, updates, renewals, backup and restore, troubleshooting, and shutting everything down. The daily commands are in [usage.md](usage.md). Commands run as user `ns` on ns-main unless a block says root.

## Do this first: a calendar

| When | What | How |
|---|---|---|
| Every 5 minutes, automatic | Dead or silent run check | the `ns check` timer; one ntfy line per incident |
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

`ns up` runs `ns doctor`, restarts the Remote Control session (tmux `rc`) and lists parked runs. `ns resume --all` restarts every parked or crashed run; runs you stopped with `ns stop` or `ns kill` stay stopped (it names them) until you `ns resume <id>` them. Tailscale, Caddy, cloudflared, SilverBullet and the `ns gc` and `ns check` timers come back on their own. Claude sessions, Nightshift runs and Remote Control are started by you, on purpose, so you see the state before agents spend usage again. A plain interactive Claude session comes back with `claude --continue` in its folder.

## A run that stopped without telling you

Runs beyond `max_runs` (default 2, in `config.yaml`) wait as `queued`: `ns ls` shows `runs` in WAITING-ON and `ns status` the queue position. They start by themselves when a conductor ends; `ns dequeue` starts them by hand and `ns new --now` skips the queue. After a reboot `ns resume --all` starts as many runs as `max_runs` allows and queues the rest.

`ns ls` and `ns status` show a run's health next to its state. `dead` means the run is `running` in the ledger but its tmux session is gone: restart it with `ns resume <id>`. `silent <N>m` means the session is alive but nothing has been written to its logs (the JSONL logs, a checks log or `.checks.rc`) for that long (threshold `NS_SILENT_SECS`, default 1200): look with `ns attach <id>`. A run whose conductor is running `ns-conductor checks` is not silent while the checks have run for less than `NS_CHECKS_MAX_SECS` (default 3600); a check that runs longer may hang and counts as silent again. The `ns-health.timer` runs `ns check` every 5 minutes and sends one ntfy message per incident.

## Cleanup: what `ns gc` drops

`ns gc` runs daily at 04:00 from a systemd timer, and its monthly tasks run on the 1st. To see what it would do without doing it:

```bash
ns gc --dry-run
```

It ends with one ntfy line such as "freed 3.1 GB, 1 item(s) need you, reboot required, disk 85%", and it warns when the disk is 80 % full or more.

`ns gc` only drops runs that are `done` and merged or closed. To clear a stopped, failed or parked run, use `ns rm <id>` (or `ns rm --all-stopped`); see `docs/usage.md`.

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

To cut a release, merge the pull request, then run `ns tag vX.Y.Z` in your dev clone as the owner (see [usage.md](usage.md#ns-tag)). It checks the base branch, runs the project checks, warns when runs are active (since the upgrade refuses then), pushes the tag and prints the upgrade command below.

Nightshift runs from a release under `/opt/nightshift/<tag>`, not from your dev clone. Your dev clone `~/Coding/nightshift` is never involved in an update. To install a release or go back to an older one, as root:

```bash
/opt/nightshift/current/bin/bootstrap.sh --upgrade <tag>
```

It installs `/opt/nightshift/<tag>` if missing, repoints `/opt/nightshift/current` to it, re-pins the plugin marketplace and plugins to that tag, and reinstalls the `ns-gc` and `ns-health` timers from the new release. Earlier releases stay in place, and a run keeps using the release it started on (recorded as `release` in its ledger): its scripts and its plugins (agents, skills and the guard hook), which `ns-launch` loads with `--plugin-dir /opt/nightshift/<release>/plugins/...` when the release is not `current`. A plugin loaded with `--plugin-dir` replaces the installed marketplace plugin of the same name for that session (checked with Claude Code 2.1.291: the session's plugin list shows `ns@inline` and `ns-python@inline` and no `ns@nightshift` or `ns-python@nightshift`, and each agent once), so hooks and agents do not load twice. A stack plugin that the run's project does not use is not passed, so the current release's copy of it stays loaded from the marketplace. Keep an old release until no run points at it; old releases are never removed for you yet (issue #152).

The upgrade, and every other `bootstrap.sh` run that changes the install, refuses with exit 1 while a job is live: a run's tmux session, its conductor process or one of its workers. It lists each as `id  state  release  pid`. Runs at a gate, queued or parked are listed as information and do not block, since they resume on their own release; a run that is `running` in its ledger with nothing alive is shown as `looks dead: ns kill <id> or ns stop <id>` and does not block either. `--force` proceeds anyway. Before forcing, check the release notes for changed `ns-conductor` interfaces: a live conductor keeps running the release it started on, but the tools it calls from `PATH` may change under it. For example, since issue #12 `ns-conductor review-round` needs a third argument, the review's verdict (`approve` or `changes`), and a two-argument call exits 2. Since issue #71 `review-round approve` also needs this round's review file with `REVIEW verdict=approve head=<sha>` (exit 9 otherwise), and `ns-conductor merge` exits 8 without an approved review of the current phase head: an older release's skills, which know neither, stop at those exits. While `bootstrap.sh` runs it holds `/opt/nightshift/.upgrade.lock`, and `ns new`, `ns resume`, `ns dequeue` and `ns approve` refuse to start a conductor until it is gone (a run that was already past that check is queued; the `ns-health` timer's `ns dequeue` starts it within about 5 minutes after the upgrade, or the next conductor that ends does). Before it lists the jobs, `bootstrap.sh` waits for the queue lock (`~/.config/ns/queue.lock`, up to 130 s, `NS_BS_QUEUE_WAIT`), so a conductor start already in flight finishes first and shows up in the list; if the lock stays busy it refuses unless `--force`. The upgrade lock names the pid of its `bootstrap.sh`: a lock whose pid is gone or belongs to another program is stale and ignored with a warning, and a lock without a readable pid counts as held. If no `bootstrap.sh` runs and the lock stays, remove it with `sudo rm /opt/nightshift/.upgrade.lock`. `bootstrap.sh` reads the pid files under `~ns/.config/ns` only when they are regular files (not symlinks), and only their first bytes; it drops control characters from the ledger fields it prints.

Update the plugins only this way. Never run `claude plugin update`, `claude plugin marketplace update` or `claude plugin install` for `ns@nightshift` by hand: the marketplace is pinned to the installed tag (`~/.config/ns/release-pin`), and a hand update would change the agents and the guard of live runs without the check above.

Rollback is the same command with the previous tag:

```bash
/opt/nightshift/current/bin/bootstrap.sh --upgrade <previous tag>
```

Check afterwards, as `ns`:

```bash
ns doctor
```

Do it between runs: `ns drain` first (it parks the running runs, which then do not block), then `ns resume --all` afterwards. Other updates:

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

1. Edit the desk documents as the escalation asks (for example give more budget by raising `budget_hours` in a `# Budget exceeded` escalation, or change the plan).
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

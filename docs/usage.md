# Using Nightshift

You queue work for Nightshift with the `ns` command on the server, then review what it produced at the review desk the next morning. This page lists the commands, the gates that stop work from going further, and where to look.

## The ns command

Exit codes: 0 ok, 1 failure, 2 usage error; every command has --help.

### ns help

```
ns help
```

`ns help` lists every command with a one-line summary. Running `ns` with no arguments does the same.

Example:

```
$ ns help
usage: ns <command> [args]

commands:
  help       list commands
```

### ns profile check

```
ns profile check [path] [--repo <dir>]
```

`ns profile check` validates a project profile (`path` is a repo directory or a profile file, default `.`) and prints `ok: <file>`, or one line per problem and exit code 1. Problems are: invalid YAML, schema errors, a missing docs file, domain skill or workflow, an unknown stack, and a specialist or risk-zone agent that is not available. `--repo` names the repository the referenced files are looked up in. The keys are listed in [profile-reference.md](profile-reference.md).

### ns profile show

```
ns profile show [path]
```

`ns profile show` prints the resolved profile as JSON: defaults applied, stacks as objects, and the `checks` (lint and test per stack) that will run. See [profile-reference.md](profile-reference.md) for every key.

### ns project add

```
ns project add <owner/repo> --prefix <p> [--sandbox] [--branch <b>]
```

`ns project add` registers a project in `~/.config/ns/projects.yaml`. The prefix is 1 to 10 lowercase letters or digits, starting with a letter, and is unique per project. If `~/Coding/<repo>` already exists and its `origin` is `owner/repo`, it is adopted as the main checkout: nothing in it is cloned, checked out, pulled or changed, and only `git fetch origin` runs. If it exists with another origin the command stops with an error; if it is absent the repo is cloned with `gh`. The token file `~/.config/ns/tokens/<owner>` (mode 600) is used when it exists.

The profile is read from the base branch (or from `--branch`) and checked in a temporary worktree; an invalid profile registers nothing. The stacks' setup runs there once, then the worktree is removed, the desk folder `/srv/ns-space/<repo>/runs` is created and the project is registered. If the base branch has no `.claude/project-profile.yaml`, the command registers the project and starts the onboarding run `<prefix>-onboard` (see `ns new --onboard` below). `--sandbox` marks the project as an end-to-end test target; `--branch` stores the ref the profile and base branch are read from.

Running it again with the same repo and prefix prints `already registered` and exits 0. A different prefix for a registered repo, or a prefix used by another repo, exits 1.

### ns new

```
ns new <prefix>-<n> [--tier T0..T3] [--yes]
ns new <prefix> "<text>" [--tier T0..T3] [--yes]
ns new <prefix>-onboard --onboard
```

`ns new` starts a run. `sbx-12` runs GitHub issue 12 of the project with prefix `sbx`; `ns new sbx "text"` runs free text and gets the id `sbx-x1`, then `sbx-x2` and so on. The command creates a worktree `~/Coding/worktrees/<repo>-<id>` on the branch `plan/<id>` from `origin/<base branch>`, runs the project's setup there, writes and pushes the run ledger (state `queued`), adds the run to `~/.config/ns/runs.yaml`, and starts the conductor in a detached tmux session named `<id>` (`ns attach <id>` to watch it). The session runs `ns-launch`, which starts Claude headless; its stream is logged to `~/.config/ns/logs/<id>/conductor.jsonl` and shown as one line per event.

`--tier T0..T3` sets the tier yourself (source `owner`) and its time budget from the profile, and skips triage. Without `--tier`, the conductor triages the request first, in the foreground: it prints the start of its `triage.md` and asks `Run <id> as <T> (budget <h> h)? [Y/n/T0/T1/T2/T3]`. Enter or `Y` takes the recommendation (source `triage`), a tier takes that tier (source `owner`), and `n` marks the run `stopped`. `--yes` answers `Y` without asking.

If the run already exists, `ns new` prints `already running` and exits 0 when its tmux session is alive, and otherwise exits 1 and points to `ns resume`. A project whose base branch has no `.claude/project-profile.yaml` is refused until it has one: if the onboarding pull request is open, the message names it.

`--onboard` starts the onboarding run `<prefix>-onboard`: tier T1, source `owner`, the T1 budget, no triage question, using the default profile. `ns project add` starts it automatically for a repo without a profile.

### ns ls

```
ns ls [--all] [--json]
```

`ns ls` lists the runs in `~/.config/ns/runs.yaml`, oldest first, one line each: ID, TIER (`-` before a tier is set), PHASE (the phases that are running or in review, else the ledger's step), STATE, WAITING-ON and AGE. WAITING-ON is `owner:gate<g>` when the run waits at a gate, `pool` when a phase is queued for a free worker, and otherwise `-`. A run whose worktree has been deleted shows state `?` and `no-worktree`. With no runs it prints `no runs`. `--all` includes archived runs; `--json` prints an array of `{id, project, tier, state, gate, step, phases, created}`.

### ns status

```
ns status <id> [--json]
```

`ns status` shows one run: tier and where it came from, state, gate and step, the time budget used, the branches and pull request, every phase with its attempts and review rounds, and the last five ledger events. `--json` prints the whole ledger, the same as `ns-ledger get`.

### ns attach

```
ns attach <id>
```

`ns attach` attaches your terminal to the run's tmux session (detach with `Ctrl-b d`; the run keeps going). If the session does not exist it exits 1 with `no tmux session <id>: start it with ns resume <id>`.

### ns stop

```
ns stop <id>
```

`ns stop` asks a run to stop at its next checkpoint: it sets `stop_requested` in the ledger, records a `stop-requested` event and commits the ledger. The conductor notices at its next check, parks its workers and ends the session with state `stopped`. A run that is already `stopped`, `parked`, `done` or `failed` prints `<id> is already <state>` and nothing changes.

### ns resume

```
ns resume <id>
ns resume --all
```

`ns resume` restarts a parked or stopped run, or one that crashed (state `running` but no tmux session). It rebuilds a deleted run worktree from the run's branch (local, else `origin`), marks phases whose `Plan-Phase: <phase>` trailer is already on the feature branch as `merged`, resets `running` phases without a live worker to `pending`, sets the state to `running`, records a `resumed` event, pushes the ledger and starts the conductor in a new tmux session. A run that is already running prints `<id> is already running`; a `done` or `failed` run prints `<id> is <state>; nothing to resume`; a run waiting at a gate tells you to edit the desk documents and `ns approve` it. `--all` does this for every non-archived run that is parked, stopped or crashed and leaves the others alone.

### ns drain

```
ns drain [--timeout <s>]
```

Run `ns drain` before a reboot. For every non-archived run that is `running` or `queued`, it sets `stop_requested` to `parked` (when the run has a tmux session) or parks the run directly (when it has none), then checks the ledgers every 10 seconds until no run is `running` and prints `parked: <ids>`. If that takes longer than `--timeout` (default 1800 seconds) it prints `still running: <ids>` and exits 1. Runs that are `waiting` at a gate are left alone.

### ns up

```
ns up
```

Run `ns up` after a reboot. It runs `ns doctor` and keeps its exit code, starts the tmux session `rc` with `claude remote-control --spawn worktree` in `remote_control_dir` (from the config, else the first registered project's path) unless it already exists, then lists parked runs and the hint `ns resume --all`. `ns up` exits with the exit code of `ns doctor`.

### ns doctor

```
ns doctor [--no-claude]
```

`ns doctor` checks the server and prints one line per check: `ok   <check>: <detail>`, `warn <check>: <detail>` or `FAIL <check>: <detail>`. It exits 1 if any check is a `FAIL`. The checks, in order:

1. The commands `git tmux jq python3 gh claude curl` and the Python modules `yaml` and `jsonschema`.
2. `gh auth status`.
3. Every file in `tokens/`: mode other than 600 is a `FAIL`. The expiry comes from the `github-authentication-token-expiration` header of `gh api -i user`: past is a `FAIL`, under 14 days a `warn`, unreadable a `warn` (`expiry unknown`). The token value is never printed.
4. `projects.yaml` parses and every project path exists.
5. The desk directory exists and is writable.
6. `NS_NTFY_TOPIC` and `NS_DESK_URL` are set (`warn` if not).
7. The services `silverbullet` and `ns-gc.timer` (user units), `caddy` and `cloudflared` are active (`FAIL` if not; without `systemctl` a `warn`).
8. `NS_DESK_URL` answers with an HTTP status from 200 to 403, else `FAIL`.
9. Disk use: 80 % or more is a `warn`, 95 % or more a `FAIL`.
10. A pending reboot is a `warn`.
11. Auto permission mode works in a headless call (`ns-conductor check-auto`). On failure the `FAIL` line carries the hint to set `NS_WORKER_MODE=bypassPermissions` (R-CON-4). `--no-claude` skips this call and prints a `warn`.
12. A run in state `running` without a tmux session is a `warn`: `run <id> has no session: ns resume <id>`.

### ns gc

```
ns gc [--dry-run] [--monthly]
```

`ns gc` is housekeeping; a systemd timer runs it daily at 04:00. For every non-archived run that is `done` and whose PR is merged or closed it removes the run's worktrees, its local branches (`git branch -d`, so unmerged ones are kept), its remote `plan/` and phase branches (never the base branch) and its tmux session, moves its desk folder to `archive/<yyyy-mm>/<id>`, regenerates the desk index and marks the run archived. Desk archive folders older than 90 days are deleted. A worktree with uncommitted or unpushed work is never touched: it is reported as `needs you: <path>: <reason>` and its run is kept whole, as are runs that are not `done` or whose PR is still open. Project `.claude/worktrees/*` holding work are reported too. On the 1st of the month, or with `--monthly`, the stacks' `gc.monthly` targets (for Python `~/.cache/pip`) are removed.

Every action prints `remove <kind> <target>`. `--dry-run` prints `would remove ...` for the same items and changes nothing. The last line is a summary such as `ns gc: freed 1.2MB · 1 item(s) need you · reboot required · disk 85%`; it is sent with `ns-notify` (not in a dry run). When `NS_HEALTHCHECK_URL` is set and nothing failed, that URL is pinged. Exit 0, or 1 when an action failed.

### ns publish

```
ns publish <id> <file>[:<name>]...
```

`ns publish` copies documents from the run worktree to the review desk. A leading `RUN/` in a file means `.nightshift/runs/<id>/`; other relative paths are resolved against the run worktree, and every file must lie inside it. The name defaults to the file's basename and must match `[A-Za-z0-9._-]+.(md|html|yaml|env)`. The copy gets mode 0640. HTML must be self-contained: an external `<script src>`, a `<link href="http...">` or an `@import` is refused. A file that looks like it contains a token is refused. Nothing is copied unless every file passes. After copying, `ns publish` records the file in `.published`, regenerates the repo's `index.md` and sends a notification through `ns-notify`: `<id>: gate <g> needs you` when the run waits at a gate, else `<id>: <n> document(s) published`. With `NS_DESK_URL` set, the notification links to the first document. Without `NS_NTFY_TOPIC` no notification is sent (`ns-notify` says so on stderr).

`ns-notify "<text>" [url]` is the notification helper `ns publish` uses. It posts to `NS_NTFY_URL` (default `https://ntfy.sh`) under the topic `NS_NTFY_TOPIC`, cuts the text to 200 characters and refuses text that looks like a token.

### ns approve

```
ns approve <id> [--yes]
```

`ns approve` releases the gate a run waits at. For every published Markdown and YAML document it prints a unified diff between the branch copy and your desk copy (labels `branch:<source>` and `desk:<name>`), or `no changes: <name>`. Then it asks `Commit the desk versions and release gate <g> of <id>?`; answering anything but `y` prints `Nothing changed.` and exits 1 without touching files or the ledger. On yes it copies the changed desk files into the run worktree (HTML documents are never copied back), commits them with the trailer `Approved-By: owner` (an empty commit if nothing changed), clears the gate, records an `approved` event, pushes the ledger and runs `ns resume`, which starts the conductor again. A run that is not at a gate prints `<id> is not waiting at a gate; nothing to approve` and exits 0.

`--yes` skips the question. It is only allowed for projects added with `--sandbox`, otherwise `ns approve` exits 2.

An onboarding run (`<prefix>-onboard`) is approved differently: the desk files `project-profile.yaml`, `ns-github.env` and `<prefix>-invariants.md` are committed to a new branch `nightshift/onboard` cut from the base branch, as `.claude/project-profile.yaml`, `.claude/ns-github.env` and `.claude/skills/<prefix>-invariants/SKILL.md`. `ns approve` pushes the branch, opens a pull request with `gh pr create`, records its URL in the ledger, sets the run to `done` and does not start a conductor. It never merges the pull request: merge it yourself, then `ns new` works for the project.

## Commands inside Claude Code

## Tiers and gates

## The review desk

The desk is a folder (`NS_DESK_DIR`, default `/srv/ns-space`) where runs put what you need to read and edit:

```
<desk>/<repo>/index.md                     one table row per run: tier, state, gate, documents
<desk>/<repo>/runs/<id>/<name>             the published documents
<desk>/<repo>/runs/<id>/.published         name, source path in the run worktree, sha256 of the copy
```

Markdown and YAML documents are editable: change them in place, and `ns approve` commits your versions to the run branch before it releases the gate. HTML documents are read-only views; edit their Markdown source instead. Git stays the source of truth: the desk holds copies, and a document only counts once it is committed on the run's branch. `index.md` is regenerated by every `ns publish`.

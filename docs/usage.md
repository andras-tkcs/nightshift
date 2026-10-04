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

`ns new` starts a run. `sbx-12` runs GitHub issue 12 of the project with prefix `sbx`; `ns new sbx "text"` runs free text and gets the id `sbx-x1`, then `sbx-x2` and so on (a number whose `plan/<id>` branch already exists on GitHub, say from another machine, is skipped). The command creates a worktree `~/Coding/worktrees/<repo>-<id>` on the branch `plan/<id>` from `origin/<base branch>`, runs the project's setup there, writes and pushes the run ledger (state `queued`), adds the run to `~/.config/ns/runs.yaml`, and starts the conductor in a detached tmux session named `<id>` (`ns attach <id>` to watch it). The session runs `ns-launch`, which starts Claude headless; its stream is logged to `~/.config/ns/logs/<id>/conductor.jsonl` and shown as one line per event.

`--tier T0..T3` sets the tier yourself (source `owner`) and its time budget from the profile, and skips triage. Without `--tier`, the conductor triages the request first, in the foreground: it prints the start of its `triage.md` and asks `Run <id> as <T> (budget <h> h)? [Y/n/T0/T1/T2/T3]`. Enter or `Y` takes the recommendation (source `triage`), a tier takes that tier (source `owner`), and `n` marks the run `stopped`. `--yes` answers `Y` without asking.

If the run already exists, `ns new` prints `already running` and exits 0 when its tmux session is alive, and otherwise exits 1 and points to `ns resume`. A project whose base branch has no `.claude/project-profile.yaml` is refused until it has one: if the onboarding pull request is open, the message names it.

`--onboard` starts the onboarding run `<prefix>-onboard`: tier T1, source `owner`, the T1 budget, no triage question, using the default profile. `ns project add` starts it automatically for a repo without a profile.

### ns ls

```
ns ls [--all] [--json]
```

`ns ls` lists the runs in `~/.config/ns/runs.yaml`, oldest first, one line each: ID, TIER (`-` before a tier is set), PHASE (the phases that are running or in review, else the ledger's step), STATE, WAITING-ON, AGE, ELAPSED (since the run was created) and LAST-OUT (since the newest log under `logs/<id>/` was written, `-` when there is none). A run in state `running` with no open gate shows its health in the STATE column when it is not `ok`: `dead` when its tmux session or pane process is gone, `silent <N>m` when its log has not grown for `NS_SILENT_SECS` seconds (default 1200). An open gate is never silent. WAITING-ON is `owner:gate<g>` when the run waits at a gate, `pool` when a phase is queued for a free worker, and otherwise `-`. A run whose worktree has been deleted shows state `?` and `no-worktree`. With no runs it prints `no runs`. `--all` includes archived runs; `--json` prints an array of `{id, project, tier, state, gate, step, phases, created, health, elapsed_s, idle_s}`; `health` is `ok`, `dead` or `silent <N>m`, `idle_s` is null without a log.

### ns status

```
ns status <id> [--json]
```

`ns status` shows one run: tier and where it came from, state, gate and step, the time budget used, the branches and pull request, every phase with its attempts and review rounds, and the last five ledger events. A `health` line says `ok`, `dead` or `silent <N>m` as in `ns ls`. `--json` prints the whole ledger, the same as `ns-ledger get`.

### ns attach

```
ns attach <id>
```

`ns attach` attaches your terminal to the run's tmux session (detach with `Ctrl-b d`; the run keeps going). If the session does not exist it exits 1 with `no tmux session <id>: start it with ns resume <id>`.

### ns log

```
ns log <id> [-f] [--phase <p>] [--raw]
```

`ns log` prints a run's session logs (`~/.config/ns/logs/<id>/*.jsonl`, the conductor and every phase worker) as readable text: one event per entry, never truncated, wrapped to the terminal width (`COLUMNS`, default 80) with a hanging indent under the text. Tool calls show their command or file path (else the compact JSON input); tool results show one short line, `result: ok` or `result: error, exit N: <first error line>`. `--phase <p>` shows only `logs/<id>/<p>.jsonl`, `--raw` prints the JSONL unchanged, `-f` follows new output (`tail -f`). It exits 1 with a message if the run has no logs or the phase has no log.

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
7. The services `silverbullet` and `ns-gc.timer` and `ns-health.timer` (user units), `caddy` and `cloudflared` are active (`FAIL` if not; without `systemctl` a `warn`).
8. `NS_DESK_URL` answers with an HTTP status from 200 to 403, else `FAIL`.
9. Disk use: 80 % or more is a `warn`, 95 % or more a `FAIL`.
10. A pending reboot is a `warn`.
11. Auto permission mode works in a headless call (`ns-conductor check-auto`). On failure the `FAIL` line carries the hint to set `NS_WORKER_MODE=bypassPermissions` (R-CON-4). `--no-claude` skips this call and prints a `warn`.
12. A run in state `running` without a tmux session is a `warn`: `run <id> has no session: ns resume <id>`.

### ns health-check

```
ns health-check
```

`ns health-check` is run every 5 minutes by the `ns-health.timer` user unit. For every active run it works out the health shown by `ns ls`. A run that is `dead` or `silent` sends one `ns-notify` message (`ns: <id> is dead (see ns status <id>)`) and the incident is remembered in `~/.config/ns/health/<id>`, so the next tick stays quiet; a change between `dead` and `silent` sends one more message (`silent <N>m` becoming `silent <M>m` does not). When the run is healthy again, or no longer an active run, the file is removed. The last line is a summary: `ns health-check: 3 run(s) checked, 1 unhealthy, 1 notified`.

### ns gc

```
ns gc [--dry-run] [--monthly]
```

`ns gc` is housekeeping; a systemd timer runs it daily at 04:00. It looks at every non-archived run that is `done` and has a PR, and reads the PR state with `gh` using the token of the project's owner (`tokens/<owner>` in the config directory, mode 600; without that file `gh`'s default login is used). If the token file has the wrong mode or the PR state cannot be read, the run is reported as `needs you: <id>: cannot read PR state` (or the token problem) and kept whole. The token is never printed.

For a **merged** PR it removes the run's worktrees, its local branches (`git branch -d`; a plan or phase branch that was never merged into the base is deleted only when its tip is on origin), its remote `plan/` and phase branches (never the base branch) and its tmux session, moves its desk folder to `archive/<yyyy-mm>/<id>`, regenerates the desk index and marks the run archived.

For a **closed** PR (not merged) it does the same except that it never deletes the remote branches, because `plan/<id>` holds the ledger, plan and review notes and would exist nowhere else; it prints `kept remote branches of <id> (PR closed, not merged)`. Worktrees, local branches whose tip is on origin, the tmux session are removed, and the desk folder is archived anyway (it is only a view).

Desk archive folders older than 90 days are deleted. A worktree with uncommitted or unpushed work is never touched: it is reported as `needs you: <path>: <reason>` and its run is kept whole, as are runs that are not `done` or whose PR is still open. Project `.claude/worktrees/*` holding work are reported too. On the 1st of the month, or with `--monthly`, the stacks' `gc.monthly` targets (for Python `~/.cache/pip`) are removed.

Every action prints `remove <kind> <target>`. `--dry-run` prints `would remove ...` for the same items and changes nothing. The last line is a summary such as `ns gc: freed 1.2MB · 1 item(s) need you · reboot required · disk 85%`; it is sent with `ns-notify` (not in a dry run). When `NS_HEALTHCHECK_URL` is set and nothing failed, that URL is pinged. Exit 0, or 1 when an action failed.

### ns publish

```
ns publish <id> <file>[:<name>]...
```

`ns publish` copies documents from the run worktree to the review desk. A leading `RUN/` in a file means `.nightshift/runs/<id>/`; other relative paths are resolved against the run worktree, and every file must lie inside it. The name defaults to the file's basename and must match `[A-Za-z0-9._-]+.(md|html|yaml|env)`. The copy gets mode 0640. HTML must be self-contained: an external `<script src>`, a `<link href="http...">` or an `@import` is refused. A file that looks like it contains a token is refused. Nothing is copied unless every file passes. After copying, `ns publish` records the file in `.published`, regenerates the repo's `index.md` and sends a notification through `ns-notify`: `<id>: gate <g> needs you` when the run waits at a gate, else `<id>: <n> document(s) published`. With `NS_DESK_URL` set, the notification links to the first document. Without `NS_NTFY_TOPIC` no notification is sent (`ns-notify` says so on stderr).

`ns-notify "<text>" [url]` is the notification helper `ns publish` uses. It posts to `NS_NTFY_URL` (default `https://ntfy.sh`) under the topic `NS_NTFY_TOPIC`, cuts the text to 200 characters and refuses text that looks like a token. The text is sent literally (`--data-raw`), so a text starting with `@` is not read as a file. If the ntfy token file exists under `~/.config/ns/tokens/`, its token is sent as a bearer token, handed to curl on stdin so it never appears in argv. A non-2xx answer is an error: `ns-notify` says so (never printing the token) and exits 1.

### ns approve

```
ns approve <id> [--yes]
```

`ns approve` releases the gate a run waits at. For every published Markdown and YAML document it prints a unified diff between the branch copy and your desk copy (labels `branch:<source>` and `desk:<name>`), or `no changes: <name>`. Then it asks `Commit the desk versions and release gate <g> of <id>?`; answering anything but `y` prints `Nothing changed.` and exits 1 without touching files or the ledger. On yes it copies the changed desk files into the run worktree (HTML documents are never copied back), commits them with the trailer `Approved-By: owner` (an empty commit if nothing changed), clears the gate, records an `approved` event, pushes the ledger and runs `ns resume`, which starts the conductor again. A run that is not at a gate prints `<id> is not waiting at a gate; nothing to approve` and exits 0. A finished run at gate 2 (the pull request review) prints `<id> is at gate 2, the pull request review: read the handoff, then merge the PR on GitHub (/ns:review <id>); nothing to approve`, exits 0 and changes nothing. Before anything is copied, `ns approve` refuses with exit 1 if a desk file contains a token-shaped string or if a published source path leads outside the run worktree.

`--yes` skips the question. It is only allowed for projects added with `--sandbox`, otherwise `ns approve` exits 2.

An onboarding run (`<prefix>-onboard`) is approved differently: the desk files `project-profile.yaml`, `ns-github.env` and `<prefix>-invariants.md` are committed to a new branch `nightshift/onboard` cut from the base branch, as `.claude/project-profile.yaml`, `.claude/ns-github.env` and `.claude/skills/<prefix>-invariants/SKILL.md`. `ns approve` pushes the branch, opens a pull request with `gh pr create`, records its URL in the ledger, sets the run to `done` and does not start a conductor. It never merges the pull request: merge it yourself, then `ns new` works for the project.

## Commands inside Claude Code

The plugin `ns` adds these slash commands. The conductor uses most of them itself; you type `/ns:status`, `/ns:resume` and `/ns:review` yourself, and the others when you work on a repository by hand.

### /ns:run

```
/ns:run <run id> [--triage-only] [--resume] [--onboard]
```

`/ns:run` drives one run from its ledger through triage, the tier pipeline, the review board and the pull request. `ns-launch` starts it headless inside the run's tmux session. You do not type it; use `ns new` and `ns resume`. The model cannot invoke it on its own.

### /ns:plan

```
/ns:plan <what to build: the request, an issue number, or both>
```

`/ns:plan` researches a change and writes either a single-session prompt (small scope) or a plan document with an implementation manifest (large scope), plus step-by-step manual steps for anything only a human can do. Use it when you want a plan without a full run. It plans only and implements nothing.

### /ns:implement

```
/ns:implement <run id>
```

`/ns:implement` runs the phases of a plan manifest with phase workers, reviews each phase, merges them into one feature branch and runs the review board. The conductor uses it for T2 and T3 runs; use it by hand to run the phases of a plan in a run worktree.

### /ns:dod

```
/ns:dod [path or test target]
```

`/ns:dod` runs the project's definition of done (the profile's checks plus the project's `docs.dod` section) on the current branch and prints a pass/fail table. It reports and never fixes. Use it before you open or merge a pull request.

### /ns:status

```
/ns:status [run id]
```

`/ns:status` summarises one run (`ns status <id>`) or lists all runs (`ns ls`) and says what the run waits for. It only reads.

### /ns:resume

```
/ns:resume <run id>
```

`/ns:resume` restarts a parked, stopped or crashed run (`ns resume <id>`). For a run waiting at a gate it does not resume: it tells you to edit the desk documents and run `ns approve <id>`.

### /ns:review

```
/ns:review <run id>
```

`/ns:review` walks you through gate 2: it summarises the handoff report on the desk, shows the pull request with `gh pr view`, and lists the manual steps for after the merge. It never merges; you merge on GitHub.

## Tiers and gates

Triage picks a tier from the size of the request and the risk of the paths it touches (a risk zone raises it to at least T1). You can override it with `ns new --tier`.

| Tier | Typical | Pipeline | Gates | Default budget |
|---|---|---|---|---|
| T0 | typo, docs, config value | implementer, checks, PR | PR review only | 30 min, 1 review round |
| T1 | one bug | mini-plan, failing test, fix, checks, code review, PR | PR review only | 2 h, 3 review rounds |
| T2 | feature in one area | analysis, plan, tests, gate 1, 1 to 3 phases, review, integration, PR | gate 1, gate 2 | 8 h |
| T3 | epic | research, analysis, ADR, plan, tests, gate 1, parallel phases, review board, integration, PR | gate 1, gate 1.5 if needed, gate 2 | 36 h |

A run stops at a gate with state `waiting` and sends you a notification. What you do at each:

- Gate 1 (plan approval, T2 and T3): read the published plan and acceptance documents on the review desk. Edit the Markdown in place if something is wrong or an open question needs your answer, then run `ns approve <id>`. It shows the diff of your edits, commits them and starts the run again.
- Gate 1.5 (budget or escalation): the run exceeded a time or review-round budget, or hit something it cannot decide. It parks and publishes an escalation document. Answer under `## Owner's answer` in that document, then `ns approve <id>`.
- Gate 2 (pull request review): read the handoff report on the desk and the pull request (`/ns:review <id>` does this with you). Merge the pull request on GitHub yourself, then do the manual steps listed in it. Nightshift never merges.

For T0 and T1 the only stop is your review of the pull request. See [The review desk](#the-review-desk) for where the documents are.

## Daily use

tmux keeps every run alive on the server. Your device only attaches and detaches, so closing the iPad or the work browser tab never stops anything.

From the iPad (Blink Shell):

```
mosh ns@ns-main         # over Tailscale
ns ls                   # runs, tier, phase, state
ns new sbx-123          # start a run for issue 123 of project sbx
ns attach sbx-123       # jump into a run
Ctrl-b d                # detach, the run keeps going
```

From the work browser (Cloudflare):

```
https://ns-desk.<domain>     # plans, edit Markdown
https://ns-view.<domain>     # HTML reports
# terminal (Tailscale SSH console or https://ns-ssh.<domain>), then:
ns ls
ns attach sbx-123            # answer an escalation
ns status sbx-123            # read the ledger, no attach
```

## Helper commands

These sit on `PATH` next to `ns`. You rarely type them; the conductor and the `ns` commands do.

- `ns-notify "<text>" [url]` sends a push notification through ntfy (`NS_NTFY_TOPIC`); see `ns publish` above.
- `ns-ledger <subcommand> <ledger> ...` reads and updates a run's ledger; see [ledger.md](ledger.md).
- `ns-conductor <subcommand> ...` starts, waits for and stops phase workers and checks auto mode; see [conductor.md](conductor.md).
- `ns-launch <id> [--triage|--resume]` runs a run's conductor session headless and logs its stream; `ns new` and `ns resume` call it.
- `ns-gh audit|apply owner/repo` audits or applies Nightshift's GitHub repository settings; see [operations.md](operations.md).

## The review desk

The desk is a folder (`NS_DESK_DIR`, default `/srv/ns-space`) where runs put what you need to read and edit:

```
<desk>/<repo>/index.md                     one table row per run: tier, state, gate, documents
<desk>/<repo>/runs/<id>/<name>             the published documents
<desk>/<repo>/runs/<id>/.published         name, source path in the run worktree, sha256 of the copy
```

Markdown and YAML documents are editable: change them in place, and `ns approve` commits your versions to the run branch before it releases the gate. HTML documents are read-only views; edit their Markdown source instead. Git stays the source of truth: the desk holds copies, and a document only counts once it is committed on the run's branch. `index.md` is regenerated by every `ns publish`.

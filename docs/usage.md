# Using Nightshift

You queue work for Nightshift with the `ns` command on the server, then review what it produced at the review desk the next morning. This page lists the commands, the gates that stop work from going further, and where to look.

## The ns command

Exit codes: 0 ok, 1 failure, 2 usage error; every command has --help.

### Owner-only commands

Some commands are yours alone. The guard hook refuses them when an agent runs them, in any form: by a full path, behind `env`, `nohup` or `xargs`, inside `bash -c`, `eval`, a script or `$(...)`, or with the name in a variable. They are:

| Command | Why it is yours |
|---|---|
| `ns kill` | stops a run at once and kills its processes |
| `ns tag` | tags and pushes a release; Nightshift never tags (R-SEC-2) |
| `ns desk` (every subcommand) | opens a pull request in the project with the project owner's token |
| `ns stack merge`, `ns stack drop` | merge pull requests into the base branch, or close one and push a revert, with the project owner's token |
| `ns approve` | releases a gate: the gates are where you decide; for an onboarding run it also opens the pull request |
| `ns project` | registers a project, clones it with the owner's token and starts its onboarding run |
| `ns rm` (and `ns purge`) | deletes worktrees and branches, with `--remote` remote branches too, and closes pull requests |
| `ns gc` | the daily housekeeping: deletes worktrees and remote branches of merged runs |
| `ns new ... --allow-outside` | reads any file user `ns` can read into a run's request, which is pushed to GitHub |
| `ns-launch` | starts a run's conductor with the project owner's token; `ns new` and `ns resume` call it |
| `ns-gh apply` | changes a repository's GitHub settings |
| `bin/lib/ns-*.sh` and their functions | the code of the commands above; it runs only through `ns` |

Everything else stays open to agents, because runs need it or it changes nothing that matters: `ns ls`, `status`, `log`, `report`, `stack` (the list), `stop`, `resume`, `publish`, `profile`, `doctor`, `dequeue`, `drain`, `up`, `help`, `ns new` without `--allow-outside`, every command's `--help`, and the helpers `ns-conductor`, `ns-ledger`, `ns-notify` and `ns-gh audit`. Why these lines and what the guard cannot see are in [security.md](security.md#owner-only-commands).

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

Running it again with the same repo and prefix prints `already registered` and exits 0. A different prefix for a registered repo, or a prefix used by another repo, exits 1. Agents cannot run it: the guard hook blocks it.

### ns new

```
ns new <prefix>-<n> [--tier T0..T3] [--yes] [--now]
ns new <prefix> "<text>" [--tier T0..T3] [--yes] [--now]
ns new <prefix> --from-desk <path.md> [--allow-outside] [--tier T0..T3] [--yes] [--now]
ns new <prefix>-onboard --onboard
```

`ns new` starts a run. `sbx-12` runs GitHub issue 12 of the project with prefix `sbx`; `ns new sbx "text"` runs free text and gets the id `sbx-x1`, then `sbx-x2` and so on (a number whose `plan/<id>` branch already exists on GitHub, say from another machine, is skipped). The command creates a worktree `~/Coding/worktrees/<repo>-<id>` on the branch `plan/<id>` from `origin/<base branch>`, runs the project's setup there, writes and pushes the run ledger (state `queued`), adds the run to `~/.config/ns/runs.yaml`, and starts the conductor in a detached tmux session named `<id>` (`ns attach <id>` to watch it). The session runs `ns-launch`, which starts Claude headless; its stream is logged to `~/.config/ns/logs/<id>/conductor.jsonl` and shown as one line per event.

`--tier T0..T3` sets the tier yourself (source `owner`) and its time budget from the profile, and skips triage. Without `--tier`, the conductor triages the request first, in the foreground: it prints the start of its `triage.md` and asks `Run <id> as <T> (budget <h> h)? [Y/n/T0/T1/T2/T3]`. Enter or `Y` takes the recommendation (source `triage`), a tier takes that tier (source `owner`), and `n` marks the run `stopped`. `--yes` answers `Y` without asking.

At most `max_runs` conductors run at once (`~/.config/ns/config.yaml: max_runs`, default 2; ns-main sets 3, see [server.md](server.md)). When that many runs already have a live tmux session, `ns new` still creates the worktree and ledger but starts no session: the run stays `queued` and the command prints `queued <id>: 2 of 2 runs active (starts when one finishes)`. `ns dequeue` starts it, oldest first, as soon as a conductor ends. `--now` starts the run at once, past the limit. `ns resume`, `ns resume --all` and `ns approve` obey the same limit; a run that cannot start becomes `queued`.

If the run already exists, `ns new` prints `already running` and exits 0 when its tmux session is alive, and otherwise exits 1 and points to `ns resume`. A run that was removed (archived by `ns rm` or `ns gc`) cannot be resumed: `ns new` exits 1 saying it is archived and points to `ns rm <id> --forget --remote`, which frees the id (see `ns rm`). A project whose base branch has no `.claude/project-profile.yaml` is refused until it has one: if the onboarding pull request is open, the message names it.

While `bootstrap.sh` changes the install it holds `/opt/nightshift/.upgrade.lock` (base overridable with `NS_OPT`); `ns new`, `ns resume`, `ns dequeue` and `ns approve` then exit 1 with `an upgrade is in progress` before changing anything. A run that gets past that check just before the lock is taken (for example while `ns new` waits for triage) is queued instead of started (`queued <id>: an upgrade is in progress`), and `ns dequeue` starts it once the lock is gone (the `ns-health` timer runs it every 5 minutes). A lock whose pid is not a running `bootstrap.sh` (gone, or reused by another program) is ignored with a warning; a lock without a readable pid counts as held, and the message says to remove it as root once no `bootstrap.sh` runs.

`--from-desk <path.md>` takes the request from a note on the review desk (an absolute path, or one relative to the desk directory, such as `<repo>/notes/idea.md`). The resolved path (symlinks followed) must lie inside the desk directory, else the command refuses with `outside the desk directory`; a symlink inside the desk that points outside it is refused the same way. `--allow-outside` permits a file elsewhere; it is only accepted together with `--from-desk` (alone it is a usage error) and only from you: the guard blocks it for agents. A note that looks like it contains a token is refused. The note's text is copied into the run ledger's request, so the run gets an `<prefix>-x<k>` id; nothing is added to the repository and no pull request is opened. The file must exist and not be empty, and it cannot be combined with inline text, an issue number or `--onboard`. To put a note into the repo, use `ns desk import`.

`--onboard` starts the onboarding run `<prefix>-onboard`: tier T1, source `owner`, the T1 budget, no triage question, using the default profile. `ns project add` starts it automatically for a repo without a profile.

### ns stack

```
ns stack [project]
```

`ns stack` lists the open pull requests of runs, bottom to top (`main <- a <- b`), by asking GitHub (every page of open PRs), so it needs no ledgers of other runs. A run PR is one whose head branch matches the project's `fix_branch` or `feature_branch` pattern and whose `plan/<run id>` branch exists on origin. A stack belongs to the profile's base branch: only chains whose bottom PR targets it are listed, or whose bottom PR targets a run branch whose closed or merged PR targeted it (see `base closed`; a chain whose base PR is not found is listed with `base unknown`; one search of the closed PRs per project), and a line `N open run PRs target other base branches than <base> (not shown): #1, #3` counts the others. `ns stack merge` and `ns stack drop` see only the same chains. When the bases of run PRs form a cycle it warns and names the PRs in it; each PR is listed once. There is one chain per top PR, so two PRs on the same lower PR (a fork) are two chains, the lower PR in both; each chain is printed under a `chain 1`, `chain 2` heading. A PR whose base branch belongs to a PR closed without a merge is marked `base closed` (the closed PR must have been closed at or after the dependent PR was created, and no open PR may use that head name, so a reused branch name does not count); use `ns stack drop`. Columns: RUN, PR, BASE, CHECKS (`pass`, `fail`, `pending` or `none`), REVIEW (the review decision, `-` when none) and AGE. `project` is a prefix, name or `owner/repo`; without it every project is shown.

Stacking: at the end of implement, before review, and again in integrate, a run asks `ns-conductor stack-base <id>`; besides the stack merge below it also merges the base branch into the code branch when the code branch is behind it, and pushes the code branch. When another run's PR is open, the run merges the top of the stack into its code branch (a merge, never a rebase), opens its PR against that branch and records `stacked_on` in its ledger (`ns status` shows a `stacked` line). With no open run PR it targets the base branch and records the base branch name. When more than one chain of run PRs is open, `stack-base` exits 7 and the run goes to gate 1.5 so the owner picks the base (the profile's base branch or one of the chain tops). When the top run PR's checks are failing, the run stacks on the nearest PR below it whose checks are not failing (pending counts as not failing), or on the base branch, and its PR body says `Stacked on #N (checks failing on #M)`. Red PRs are pruned from the tops down before the chains are counted, so a red PR next to a green one does not send the run to gate 1.5; a PR the run already merged is never skipped. A merge conflict is resolved by the integrator; the checks then run in `/ns:dod`; when that is not possible the run goes to gate 1.5 and opens no PR. Merge the PRs bottom to top with `ns stack merge`.

```
ns stack merge [project] [--dry-run]
ns stack drop <id> [--dry-run]
```

`ns stack merge` lands the one chain of run PRs bottom to top with the project owner's token. It refuses when the bottom PR does not target the profile's base branch (its base PR is gone: drop or retarget it first). First it runs the profile checks once in a throwaway worktree of the top PR's head (`PASS`, `SKIP` or `FAIL <stack> <name>` per check, `SKIP no checks configured` when the profile has none) and stops with `stopped: checks failed on top of the stack (#N)` and the tail of the output when one fails, or `stopped: could not run the checks on top of the stack (#N)` after saying why (profile, fetch or worktree), merging nothing. Then each PR must be approved, have no failing or pending checks (read live from GitHub) and be mergeable. Before a PR is merged the PR above it is retargeted to the base branch, then the PR is merged (a merge commit, branches are kept). It stops at the first PR that is not ready, with a one-line reason, and prints `merged:` and `left:` lists; exit code 1 when anything is left. With more than one chain it refuses. `ns stack drop <id>` closes the PR of run `<id>`, merges the layer below into the PR above it, takes the dropped run's change out of it again with one revert commit (the PR above contains every commit of the layer, so without this the change would still land), pushes it and retargets it to the layer below (or the base branch); when the merge conflicts or the revert does not apply cleanly it stops, names the PR above and leaves everything open. `--dry-run` prints the plan and changes nothing. Both commands are the owner's: the guard blocks them for agents.

### ns ls

```
ns ls [--all] [--json]
```

`ns ls` lists the runs in `~/.config/ns/runs.yaml`, oldest first, one line each: ID, TIER (`-` before a tier is set), PHASE (the phases that are running or in review, else the ledger's step), STATE, WAITING-ON, AGE, ELAPSED (since the run was created) and LAST-OUT (since the newest log under `logs/<id>/` was written, `-` when there is none). A run in state `running` with no open gate shows its health in the STATE column when it is not `ok`: `dead` when its tmux session or pane process is gone, `silent <N>m` when its logs (the JSONL logs, a checks log or `.checks.rc` under `logs/<id>/`) have not grown for `NS_SILENT_SECS` seconds (default 1200) and its conductor is not running `ns-conductor checks <id>` under its tmux pane (for less than `NS_CHECKS_MAX_SECS` seconds, default 3600). An open gate is never silent. WAITING-ON is `owner:gate<g>` when the run waits at a gate, `runs` when a queued run waits for a free run slot (`max_runs`), `pool` when a phase is queued for a free worker, and otherwise `-`. A run whose worktree has been deleted shows state `?` and `no-worktree`. With no runs it prints `no runs`. `--all` includes archived runs; `--json` prints an array of `{id, project, tier, state, gate, step, phases, created, health, elapsed_s, idle_s}`; `health` is `ok`, `dead` or `silent <N>m`, `idle_s` is null without a log.

### ns status

```
ns status <id> [--json]
```

`ns status` shows one run: tier and where it came from, state, gate and step, the time budget used, the branches and pull request, every phase with its attempts and review rounds (plus `review <verdict> <head>` after a review round, and `report regenerated` when `ns-conductor report --rerun` wrote its phase report instead of the worker), and the last five ledger events. A `queue` line (`position N of M`) shows where a queued run stands. A `stacked` line names the run (or `main`) the PR is stacked on, when set. A `release` line names the Nightshift release the run started on (`-` for a dev checkout). At gate 1.5 a `question` line shows the first 200 characters of the `## Question` section of `RUN/escalation.md`. A `health` line says `ok`, `dead` or `silent <N>m` as in `ns ls`. `--json` prints the whole ledger, the same as `ns-ledger get`.

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

`ns stop` asks a run to stop at its next checkpoint: it sets `stop_requested` in the ledger, records a `stop-requested` event and commits the ledger. The conductor notices at its next check, parks its workers and ends the session with state `stopped`. A run with no live conductor (no tmux session, for example one waiting at a gate or one that died) is stopped at once: workers are reset, the state becomes `stopped` and `stop_requested` stays empty. A run parked on a usage limit (`budget.paused_until` set) is stopped at once and `paused_until` is cleared, so `ns check` does not resume it. Any other run that is already `stopped`, `parked`, `done` or `failed` prints `<id> is already <state>` and nothing changes.

### ns kill

```
ns kill <id>
```

`ns kill` stops a run now. It ends the run's tmux session, kills the conductor and every worker process group (SIGTERM, then SIGKILL, then it waits up to about 2 seconds until no live process is left in the group, so the ledger is written only after the conductor is gone), resets `running` phases to `pending`, sets the state to `stopped`, records the state event `stopped: killed by owner`, commits the ledger and sends one notification. The worktree and branches are kept and `ns resume <id>` restarts the run. On a run that is already stopped, done or failed with nothing left running it prints `<id> is already <state>`. Agents cannot run it: the guard hook blocks it.

### ns tag

```
ns tag <vX.Y.Z> [--repo <dir>] [--yes]
```

`ns tag` tags a release on the base branch (`main` unless the profile's `git.base_branch` says otherwise) of `--repo` (default: the repository of the current directory) and pushes the tag to `origin`. It refuses, with exit 1 and the reason, when the local base branch is dirty or differs from its `origin` counterpart, the name is not `vX.Y.Z`, the tag exists locally or on origin, the version is not the next patch, minor or major step after the newest tag, the repository has a `CHANGELOG.md` whose `[Unreleased]` section still has entries or which has no `[X.Y.Z]` section for the version (the message says to move the entries in the release pull request), or the project checks (`commands.test` of the profile, else `tests/lint` and `bats --jobs "$(nproc)" tests/bats`) fail. It warns, but goes on, when CI on the commit is not green, still runs or cannot be read, and when Nightshift runs are active (listed with state and release), because `bootstrap.sh --upgrade` refuses while they are. The annotated tag message is `Release <tag>` plus the merged pull request titles since the last tag: the title from each merge commit (`Merge pull request #N`) and the subject of each squash merge (`<title> (#N)`); other commits on the base branch are left out. The project checks always run locally, even when CI on the same commit is green: a tag cannot be taken back once the upgrade has run, and the suite takes a few minutes now that it runs in parallel. It asks for confirmation unless `--yes` is given, then prints the root command `/opt/nightshift/current/bin/bootstrap.sh --upgrade <tag>`. Agents cannot run it: the guard hook blocks it.

### ns resume

```
ns resume <id>
ns resume --all
```

`ns resume` restarts a parked or stopped run, or one that crashed (state `running` but no tmux session). It rebuilds a deleted run worktree from the run's branch (local, else `origin`), marks phases whose `<git.phase_trailer>: <phase>` trailer (default `Plan-Phase`, read from the run's profile: the project's prefix and the `--branch` it was added with, as `ns new` reads it) is already on the feature branch as `merged`, resets `running` phases without a live worker and `queued` phases (waiting for a pool slot) to `pending`, sets the state to `running`, records a `resumed` event, pushes the ledger and starts the conductor in a new tmux session. A run that is already running prints `<id> is already running`; a `done` or `failed` run prints `<id> is <state>; nothing to resume`; a run waiting at a gate tells you to edit the desk documents and `ns approve` it. A run keeps the release it started on: resume starts the conductor from `/opt/nightshift/<release>` (override the base with `NS_OPT`), and exits 1 naming the release when it is no longer installed. When that release is not `/opt/nightshift/current`, `ns-launch` also loads its plugins with `--plugin-dir <release>/plugins/ns` and `<release>/plugins/ns-<stack>` for each stack in the project's profile, instead of the marketplace plugins (pinned to `current`); an explicit `NS_PLUGIN_DIRS` wins. If anything fails after the state was set to `running` (the `resumed` event, the ledger commit, a token file with the wrong mode, or the tmux start; a failed `git push` is only recorded as a `push-failed` event and the run starts), the run is put back to its previous state and queue mark (a queued run stays in the queue), and the command exits 1; a ledger write that fails while phases are reconciled stops the resume before anything starts. `--all` does this for every non-archived run that is parked or crashed (state `running` with no tmux session) and leaves the others alone. A run that is `stopped` (by `ns stop`, `ns kill` or a declined triage) was stopped on purpose, so `--all` skips it and prints `<id> is stopped; resume it by name: ns resume <id>`; `ns resume <id>` restarts it.

### ns drain

```
ns drain [--timeout <s>]
```

Run `ns drain` before a reboot. For every non-archived run that is `running` or `queued`, it sets `stop_requested` to `parked` (when the run has a tmux session; a pending `ns stop` is kept, so that run ends `stopped`) or parks the run directly (when it has none), then checks the ledgers every 10 seconds until no run is `running` and prints `parked: <ids>`. If that takes longer than `--timeout` (default 1800 seconds) it prints `still running: <ids>` and exits 1. Runs that are `waiting` at a gate are left alone.

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
3. Every file in `tokens/`: mode other than 600 is a `FAIL`. Only a file whose whole name is the owner of a registered project (`tokens/<owner>`, the file `ns_token_export` reads; ASCII letters, digits and `-`) is a GitHub token and goes to GitHub; any other file is a `warn` (`not named after a registered project owner, not checked`) and is never sent anywhere. An owner file that holds an ntfy token (starts with `tk_`) is a `FAIL` and is not sent. The expiry comes from the `github-authentication-token-expiration` header of `gh api -i user`: past is a `FAIL`, under 14 days a `warn`, unreadable a `warn` (`expiry unknown`). The token value is never printed.
   `tokens/ntfy` never goes to GitHub. It must hold an ntfy token (`tk_` and 29 letters or digits, else a `FAIL`), and a test publish with it through `ns-notify` to `NS_NTFY_URL` (text `ns doctor: test publish`, priority `min`, so it arrives silently) must succeed, else a `FAIL` with `ns-notify`'s error. Without `NS_NTFY_TOPIC`, or when `NS_NTFY_URL` is not your own ntfy as `ns-notify` defines it (`https://<host>[:port]`, not ntfy.sh; the token is only for your own ntfy, R-NOT-5), the test publish is skipped with a `warn`.
4. `projects.yaml` parses and every project path exists.
5. The desk directory exists and is writable.
6. `NS_NTFY_TOPIC` and `NS_DESK_URL` are set (`warn` if not).
7. The services `silverbullet` and `ns-gc.timer` and `ns-health.timer` (user units), `caddy` and `cloudflared` are active (`FAIL` if not; without `systemctl` a `warn`).
8. `NS_DESK_URL` answers with an HTTP status from 200 to 403, else `FAIL`.
9. Disk use: 80 % or more is a `warn`, 95 % or more a `FAIL`.
10. A pending reboot is a `warn`.
11. Auto permission mode works in a headless call (`ns-conductor check-auto`). On failure the `FAIL` line carries the hint to set `NS_WORKER_MODE=bypassPermissions` (R-CON-4). `--no-claude` skips this call and prints a `warn`.
12. A run in state `running` without a tmux session is a `warn`: `run <id> has no session: ns resume <id>`.

### ns dequeue

```
ns dequeue
```

`ns dequeue` starts queued runs, oldest first, while fewer than `max_runs` conductors are live (a conductor is live when the run has a tmux session; the `rc` session is not a run). Each start re-checks the count under a lock (`~/.config/ns/queue.lock`), so concurrent calls never start more than the free slots. A started run gets a `dequeued` ledger event and one ntfy line. The last line is `ns dequeue: <n> started, <m> still queued`. `ns-launch` calls it when a conductor ends, `ns kill` and `ns stop` call it, and `ns check` calls it as a backstop; you can run it by hand.

### ns check

```
ns check
```

`ns check` also runs `ns dequeue`. It is run every 5 minutes by the `ns-health.timer` user unit. For every active run it works out the health shown by `ns ls`. A run that is `dead` or `silent` sends one `ns-notify` message (`ns: <id> is dead (see ns status <id>)`) and the incident is remembered in `~/.config/ns/health/<id>`, so the next tick stays quiet (also when a tick cannot read the run's ledger); a change between `dead` and `silent` sends one more message (`silent <N>m` becoming `silent <M>m` does not). When the run is healthy again, or no longer an active run, the file is removed. After `ns dequeue` (so queued runs keep their place) it runs `ns resume <id>` for a run paused on a usage limit once `budget.paused_until` in its ledger has passed, when the run has no open gate and is `parked` or `running` with a dead conductor (see docs/conductor.md, "Usage limits"); `ns resume` queues it when no run slot is free. The last line is a summary: `ns check: 3 run(s) checked, 1 unhealthy, 1 notified, 0 resumed after a usage limit, 0 queued`.

### ns rm

```
ns rm <id> [--force] [--remote] [--forget] [--dry-run] [--yes]
ns rm --all-stopped [--force] [--remote] [--dry-run] [--yes]
```

`ns rm` (alias `ns purge`) removes a run that `ns gc` would not touch: one that is `stopped`, `failed`, `parked` or `done`. A `running` or `queued` run is refused with a pointer to `ns stop` / `ns kill`. It removes the run's worktrees, local branches, tmux session and desk folder (moved to `archive/` on the desk) and marks the run archived, so it only shows in `ns ls --all`. It lists what will go and asks for confirmation unless `--yes` is given; `--dry-run` only prints `would remove ...` lines. A worktree with uncommitted or unpushed work is refused (`needs you: <path>: uncommitted changes`) unless `--force`. Remote branches are deleted only with `--remote`, which also closes an open PR with a comment. `--all-stopped` does this for every non-archived stopped, failed or parked run. GitHub calls use the project owner's token, as `ns gc` does. Exit 0, or 1 when a run was refused or an action failed. Agents cannot run it: the guard hook blocks it.

A run removed before has no worktree any more. `ns rm <id>` then reads the ledger from `origin/plan/<id>` (as `ns report` does) to find the feature and phase branches and the PR, so `ns rm <id> --remote` after a plain `ns rm <id>` still deletes the remote branches and closes an open PR. Without a worktree and without a ledger on origin, an archived run is cleaned up by its plan branch alone; a run that is not archived is refused. When origin cannot be fetched, `--remote` and `--forget` refuse and keep the run. A run whose worktree ledger exists is always checked against its state, archived or not (an archived run can be resumed), and an archived run with a live tmux session is refused. Because the ledger is written by agents, only the run's own branches are deleted, locally and on origin: `plan/<id>`, the profile's `git.fix_branch` or `git.feature_branch` for this id, and branches matching `git.phase_branch` for this id; any other name in the ledger is skipped with `skipped branch <b>: not a branch of <id>` (this also applies to `ns gc`). A desk folder whose archive name is already taken (an id that was forgotten, reused and removed again in the same month) goes to `archive/<yyyy-mm>/<id>-2`, `-3` and so on.

The archived entry keeps the run in `ns ls --all` and `ns report`, but it also keeps the id taken: `ns new <id>` on an archived id exits 1 with `run <id> is archived ...` and names `ns rm <id> --forget --remote`. `--forget` removes the run (as above) and then drops its entry from `~/.config/ns/runs.yaml`, printing `forgot <id>`, so `ns new <id>` can start the id again (run an issue again after an abandoned run). It only forgets a run that `ns rm` may remove (archived, or `stopped`, `failed`, `parked` or `done`), only when the removal finished (no failed step, no worktree, no local or remote plan branch left; otherwise it prints `kept the run in runs.yaml` and exits 1), and it refuses, changing nothing, while `plan/<id>` still exists on origin unless `--remote` is given in the same call, because a new run with that id would start on top of the old branch. With `--dry-run` it prints `would forget <id>` after the `would remove` lines. `--all-stopped` does not take `--forget`. A forgotten run's desk archive, logs and reports stay where they are.

### ns gc

```
ns gc [--dry-run] [--monthly]
```

`ns gc` is housekeeping; a systemd timer runs it daily at 04:00. It looks at every non-archived run that is `done` and has a PR, and reads the PR state with `gh` using the token of the project's owner (`tokens/<owner>` in the config directory, mode 600; without that file `gh`'s default login is used). If the token file has the wrong mode or the PR state cannot be read, the run is reported as `needs you: <id>: cannot read PR state` (or the token problem) and kept whole. The token is never printed.

For a **merged** PR it removes the run's worktrees, its local branches (`git branch -d`; a plan or phase branch that was never merged into the base is deleted only when its tip is on origin), its remote `plan/` and phase branches (never the base branch) and its tmux session, moves its desk folder to `archive/<yyyy-mm>/<id>`, regenerates the desk index and marks the run archived.

For a **closed** PR (not merged) it does the same except that it never deletes the remote branches, because `plan/<id>` holds the ledger, plan and review notes and would exist nowhere else; it prints `kept remote branches of <id> (PR closed, not merged)`. Worktrees, local branches whose tip is on origin, the tmux session are removed, and the desk folder is archived anyway (it is only a view).

Desk archive folders older than 90 days are deleted. A worktree with uncommitted or unpushed work is never touched: it is reported as `needs you: <path>: <reason>` and its run is kept whole, as are runs that are not `done` or whose PR is still open. Project `.claude/worktrees/*` holding work are reported too. On the 1st of the month, or with `--monthly`, the stacks' `gc.monthly` targets (for Python `~/.cache/pip`) are removed.

Every action prints `remove <kind> <target>`. `--dry-run` prints `would remove ...` for the same items and changes nothing. The last line is a summary such as `ns gc: freed 1.2MB · 1 item(s) need you · reboot required · disk 85%`; it is sent with `ns-notify` (not in a dry run). When `NS_HEALTHCHECK_URL` is set and nothing failed, that URL is pinged. Exit 0, or 1 when an action failed. Agents cannot run it: the guard hook blocks it (the timer is not an agent).

### ns desk

```
ns desk import <path.md> <repo path>
```

`ns desk import` lands a desk note in the project repo through a pull request. The path is absolute or relative to the desk directory; its first component names the project. The note is copied to `<repo path>` (relative, normalized, no `..`) on a new branch `nightshift/desk-...` cut from the base branch, pushed, and a pull request is opened with `gh pr create`. Nightshift never merges it. A `<repo path>` under `.github/workflows/` is refused (a workflow runs as CI; add one by hand), and so is a path that is, or goes through, a symlink on the base branch. A desk note that is a symlink to a file outside the desk is refused too. When a pull request from a `nightshift/desk-*` branch titled `Add <repo path> from the desk` is already open, the command prints `already open for <repo path>: <url>` and opens no second one; if the open pull requests cannot be listed it warns and goes on. Agents cannot run it: the guard hook blocks it.

### ns report

```
ns report <id>
```

`ns report` builds `runs/<id>/run-report.md` from the run ledger and prints where it wrote it. It works at any time, mid-run included. The report has a summary (wall time, active time, time waiting for you, time the run was dead or stopped, budget used against the limit, cost, tokens, review rounds, escalations with a one-line cause each, the number of checks per result, and a list of phase reports regenerated by `ns-conductor report --rerun` rather than written by the worker, when there are any); a timeline with one row per step: planning (created to gate 1), each gate wait, each phase's implement, review round and merge, each escalation (a gate 1.5 wait) and `conductor work` for running time that no other row covers (for example the work after a gate 1.5 answer; gaps of a minute or less get no row), with start, wall, active and waiting time, tokens and cost; a Tokens and cost section (per agent, per model, and the subagents); and a Checks section. Waiting time runs from the `gate` event to the matching `approved` event. Active time is wall time minus waits minus the gap before a `resumed` event that does not come from the queue (a dead or stopped run). The gap starts at the last assistant or user message in the run's session logs before the resume, but never before the previous ledger event; without session logs it starts at the previous ledger event. Usage-limit pauses (`usage-pause` to `usage-resume`) count as active time. Planning ends at gate 1, or at the first phase or review when the run has no gate 1 (T0 and T1). A run with neither (T0, T1) has its rows from the ledger's `step` events instead: planning ends at the first step change, and each step (triage, implement, integrate, ...) runs to the next. The cause of an escalation is the question that `ns-conductor gate` kept in its gate event; for a ledger written before that, the latest escalation shows the first heading of `escalation.md` and earlier ones show `cause not recorded`.

Tokens and cost come from the `result` events of the session logs in `~/.config/ns/logs/<id>/`: `conductor.jsonl` (the conductor, with every subagent it started: triage, analyst, architect, planner, reviewers, integrator) and `<phase>.jsonl` and `<phase>--attempt<n>.jsonl` (the phase worker's attempts). The result events of one session are running totals, so each session counts once, with its last result's `total_cost_usd` and `modelUsage`; the total cost is the sum over the sessions. The By agent table has one row per log file (sessions, turns, input, output, cache read and cache write tokens, cost), the By model table one row per model and the total, and the Subagents table each subagent type with its model, runs and time (a background subagent's type comes from its Agent call and its time from its task notification; without one, a foreground subagent's time is the span from its Agent call to its tool result, or for a call cut off before any result, to the latest assistant message of the log, else `no data`; an Agent call cut off before any result counts with model `unknown`); a subagent's tokens and cost are part of the agent that started it, as the logs do not split them out. A timeline row's tokens are those of the messages in it, scaled per session and model to the session's `modelUsage` (the stream's own counts are partial, output tokens in particular) (worker messages go to their phase's implement row, conductor messages to the step they fall in), and its cost is each session's cost per model shared out over its messages by weighted tokens, so the rows add up to the total. A session that was cut off before its result has tokens in the timeline but no cost (`no data`, or `at least $x` for a row that is partly covered), and the By agent table says so. When a log has no result event at all, its tokens are summed from the assistant messages (each message id counted once, with its last usage) and the Tokens line of the summary says `partial`. Cost is the list price Claude Code reports, not a bill.

`ns-conductor checks` appends to `logs/<id>/<target>.checks.log`, each run opening with a `== run <UTC>` line. The Checks section has one row per check of the last run for each target (a phase or `feature`), from that log (a log without `== run` lines is one run): target, check, `PASS`, `FAIL` or `SKIP`, its time and start. `SKIP` (pytest collected no tests) is listed again below the table, so a phase that stopped pytest from collecting is noticed. The Summary row `Full suite runs` counts the real runs of `ns-conductor checks` (the `== run` lines of all checks logs; a cache hit leaves only a `== cached <UTC>` line and is not counted); for a T0 or T1 run with more than one it reads `2 (more than one for a T1 run)`, and `no data` without a checks log. Below the table, Checks breakdown has one row per check with its number of runs and total time over all runs of all targets. A log written before the start and end lines existed gives `no data` for result and time. Missing or malformed logs give `no data` cells; they never fail the report (a number that is not finite or above 1e15 counts as missing, a line nested too deep is skipped). A token-shaped string in the report is replaced with `[redacted]` before the report is written. Everything taken from the ledger and the logs is escaped as data.

When the worktree is gone, `ns report` reads the ledger with `git show origin/<plan branch>:.nightshift/runs/<id>/ledger.yaml` and writes `<config dir>/reports/<id>/run-report.md`. The report is written and committed with the ledger automatically when a run finishes (`ns-conductor finish`, published to the desk next to the handoff report) and when `ns kill` stops it, and the integrator links it from the PR body. A failure to write or publish it never fails the run (a failed handoff report publish does; see docs/conductor.md, finish). The logs live outside the worktree, so the Tokens and cost and Checks sections work when the worktree is gone too, as long as `logs/<id>/` is there. Publish it by hand with `ns publish <id> RUN/run-report.md`.

### ns publish

```
ns publish <id> <file>[:<name>]...
```

`ns publish` copies documents from the run worktree to the review desk. A leading `RUN/` in a file means `.nightshift/runs/<id>/`; other relative paths are resolved against the run worktree, and every file must lie inside it. The name defaults to the file's basename and must match `[A-Za-z0-9._-]+.(md|html|yaml|env)`. The copy gets mode 0640. HTML must be self-contained: an external `<script src>`, a `<link href="http...">` or an `@import` is refused. A file that looks like it contains a token is refused. Nothing is copied unless every file passes. After copying, `ns publish` records the file in `.published`, regenerates the repo's `index.md` and sends a notification through `ns-notify`: `<id>: gate <g> needs you` when the run waits at a gate, else `<id>: <n> document(s) published`. With `NS_DESK_URL` set, the notification links to the first document. Without `NS_NTFY_TOPIC` no notification is sent (`ns-notify` says so on stderr).

At gate 1.5 the notification reads `<id>: gate 1.5 needs you: <question>`, taken from the `## Question` section of `RUN/escalation.md`.

`ns-notify "<text>" [url]` is the notification helper `ns publish` uses. It posts to `NS_NTFY_URL` (default `https://ntfy.sh`) under the topic `NS_NTFY_TOPIC`, cuts the text to 200 characters and refuses text that looks like a token. The text is sent literally (`--data-raw`), so a text starting with `@` is not read as a file. `NS_NTFY_URL` and `NS_NTFY_TOPIC` come from `~/.config/ns/env`. If the ntfy token file `~/.config/ns/tokens/ntfy` exists and `NS_NTFY_URL` is your own ntfy, its token is sent as a bearer token, handed to curl in a config on stdin so it never appears in argv; curl runs with `-q`, so a `~/.curlrc` cannot make it print the header. "Your own ntfy" is an allowlist: `NS_NTFY_URL` must be exactly `https://<host>[:port]` (an optional trailing `/`, no path; the host only ASCII letters, digits, `.` and `-`, so no `%`, `@` or `\`), and the host, lowercased and without trailing dots, must not be `ntfy.sh` or a subdomain of it; for example `https://ns-main.<tailnet>.ts.net:8444`. With any other value, unset included, the message is sent without the token and `ns-notify` warns `not sending the ntfy token: NS_NTFY_URL must be https://<your own ntfy host>[:port], not ntfy.sh`. The file must be mode 600 (`ns-notify: token file <path> must be mode 600`, as for GitHub token files) and its first line must be an ntfy token, `tk_` and 29 letters or digits (`... does not hold an ntfy token`); otherwise nothing is sent and `ns-notify` exits 1. When curl cannot reach the server, `ns-notify` prints `ns-notify: could not reach ntfy` and then curl's own error line (for example `curl: (6) Could not resolve host: ...`) and exits 1. A non-2xx answer is an error: `ns-notify` says so (`ntfy answered HTTP <code>`, or `HTTP ?` when the answer is not a 3-digit code; never printing the token) and exits 1. `NS_NTFY_PRIORITY` (`min`, `low`, `default`, `high`, `max` or `1` to `5`) sets ntfy's `Priority` header; any other value is a usage error. Text holding an ntfy token (`tk_` and 29 letters or digits) counts as a token and is refused, as by `ns publish`.

### ns approve

```
ns approve <id> [--yes]
```

`ns approve` releases the gate a run waits at. For every published Markdown and YAML document it prints a unified diff between the branch copy and your desk copy (labels `branch:<source>` and `desk:<name>`), or `no changes: <name>`. Then it asks `Commit the desk versions and release gate <g> of <id>?`; answering anything but `y` prints `Nothing changed.` and exits 1 without touching files or the ledger. On yes it copies the changed desk files into the run worktree (HTML documents and the handoff report `handoff.md` are never copied back), commits them with the trailer `Approved-By: owner` (an empty commit if nothing changed), clears the gate, records an `approved` event, pushes the ledger and runs `ns resume`, which starts the conductor again. A run that is not at a gate prints `<id> is not waiting at a gate; nothing to approve` and exits 0. A finished run at gate 2 (the pull request review) prints `<id> is at gate 2, the pull request review: read the handoff, then merge the PR on GitHub (/ns:review <id>); nothing to approve`, exits 0 and changes nothing. Before anything is copied, `ns approve` refuses with exit 1 if a desk file contains a token-shaped string or if a published source path leads outside the run worktree.

`--yes` skips the question. It is only allowed for projects added with `--sandbox`, otherwise `ns approve` exits 2. Agents cannot run `ns approve`: the guard hook blocks it, because releasing a gate is your decision.

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

`/ns:dod` runs the project's definition of done (the profile's checks plus the project's `docs.dod` section) on the current branch and prints a pass/fail table. Inside a run it takes the profile checks from `ns-conductor checks <id> feature`. It reports and never fixes. Use it before you open or merge a pull request.

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
| T1 | one bug | mini-plan, failing test, fix, code review, one full suite run, PR | PR review only | 2 h, 3 review rounds |
| T2 | feature in one area | analysis, plan, tests, gate 1, 1 to 3 phases, review, integration, PR | gate 1, gate 2 | 8 h |
| T3 | epic | research, analysis, ADR, plan, tests, gate 1, parallel phases, review board, integration, PR | gate 1, gate 1.5 if needed, gate 2 | 36 h |

A run stops at a gate with state `waiting` and sends you a notification. What you do at each:

- Gate 1 (plan approval, T2 and T3): read the published plan and acceptance documents on the review desk. Edit the Markdown in place if something is wrong or an open question needs your answer, then run `ns approve <id>`. It shows the diff of your edits, commits them and starts the run again.
- Gate 1.5 (budget or escalation): the run exceeded a time or review-round budget, or hit something it cannot decide. It parks and publishes an escalation document. Answer under `## Owner's answer` in that document, then `ns approve <id>`. For a time budget the document is `# Budget exceeded` and its answer holds the line `budget_hours: <limit>`: raise the number to give the run more time (`ns approve` sets it as the new limit before it resumes the run), or run `ns stop <id>` to end it. Approving with the number unchanged brings the run straight back to gate 1.5.
- Gate 2 (pull request review): read the handoff report on the desk and the pull request (`/ns:review <id>` does this with you). Merge the pull request on GitHub yourself, then do the manual steps listed in it. Nightshift never merges.

For T0 and T1 the only stop is your review of the pull request, unless the run escalates at gate 1.5. See [The review desk](#the-review-desk) for where the documents are.

The time budget is wall-clock hours while the run is `running`: time the run spends queued, waiting at a gate, parked, stopped, dead before a resume, or paused on a usage limit is not counted. Every way back to `running` (`ns resume`, `ns resume --all`, `ns dequeue`, `ns approve`, a new conductor from `ns-launch`) restarts the clock. The budget is checked deterministically on every tier: by `ns-conductor` between steps and before checks, review rounds, phases and the pull request, and by the plugin's hooks on every tool call of the conductor and when its session ends. Once `used` reaches the limit the run stops its workers and waits at gate 1.5.

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

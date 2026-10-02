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

## Commands inside Claude Code

## Tiers and gates

## The review desk

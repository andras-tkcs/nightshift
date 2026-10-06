# The run ledger

Every Nightshift run keeps one ledger: a YAML file that records the run's state, tier, budget, phases and events. The conductor, the `ns` commands and the review desk all read it, and `ns-ledger` is the only thing that should write it.

## Where it lives

The ledger is `.nightshift/runs/<id>/ledger.yaml`, committed on the run branch `plan/<id>` for every tier (ADR 0002: a T0 or T1 fix branch would otherwise carry the ledger into the project's pull request). The run worktree stays on `plan/<id>`; T0 and T1 code lives on `fix/<id>` in its own worktree, T2 and T3 code on the feature branch.

The directory also holds a `.gitignore` with `*.lock` and `*.tmp.*`, so the lock file and temporary files are never committed.

## Format

The format is defined by `schema/ledger.schema.json` (JSON Schema 2020-12, no unknown keys).

```yaml
version: 1
id: sbx-12                       # ^[a-z][a-z0-9]{0,9}-([0-9]+|x[0-9]+|onboard)$
project: nightshift-sandbox
request: {issue: 12}             # or {text: "..."}; exactly one key
tier: T2                         # null | T0..T3
tier_source: owner               # null | triage | owner   (owner = --tier)
tier_recommended: T2             # null | T0..T3, triage's own recommendation
tags: [python, "risk:policy"]    # from triage
state: running                   # queued|running|waiting|parked|stopped|done|failed
gate: null                       # null | "1" | "1.5" | "2"
step: phases                     # intake|triage|discovery|gate1|implement|phases|board|integrate|onboard|done
stop_requested: null             # null | stopped | parked
branch: plan/sbx-12
release: v0.1.0                 # Nightshift release the run started on; null for a dev checkout. Resume and workers use it
feature_branch: null             # feature/12 (T2/T3) or fix/sbx-12 (T0/T1), set when created
queued_for_slot: false           # true while the run waits for a free run slot (max_runs); only then does ns dequeue start it
stacked_on: null                 # null | the base branch (git.base_branch) | run id of the PR this run is stacked on (ns-conductor stack-base)
pr: null                         # PR URL
created: 2026-10-02T21:00:00Z
updated: 2026-10-02T21:05:00Z
budget: {used: 0.0, limit: null, paused: false, since: 2026-10-02T21:00:00Z}   # hours
phases:
  - {id: p1-x, title: "...", state: pending, branch: null, worktree: null, attempts: 0, review_rounds: 0}
events:
  - {time: 2026-10-02T21:00:00Z, type: created, note: "..."}
```

Phase states are `pending|queued|running|review|merged|failed|blocked`. An event `type` matches `^[a-z][a-z0-9-]*$`; the types in use are `created, triage, tier, state, gate, approved, phase-start, phase-end, review, merge, escalation, usage-pause, usage-resume, resumed, recovered, stop-requested, push-failed, note`.

`ns report <id>` turns these events into a timeline; see docs/usage.md.

Timestamps are UTC, written as quoted strings `YYYY-MM-DDTHH:MM:SSZ`. Tests and scripts can pin the clock with `NS_NOW`.

## Subcommands

`ns-ledger` is on `PATH` for conductor sessions. Every write takes an exclusive lock on `<ledger>.lock` (waiting up to 30 seconds, then exiting 1 with `ledger busy`), validates the result against the schema and replaces the file atomically, so a write that fails validation leaves the old file in place. Exit codes: 0 ok, 1 failure, 2 usage error.

### init

```
ns-ledger init <ledger> --id <id> --project <p> (--issue <n> | --text <t>) --branch <b>
```

Creates the directory, the `.gitignore` and the ledger (state `queued`, step `intake`, budget used 0, limit null, event `created`). If the ledger exists it exits 1 with `ledger exists: <path>`.

```
ns-ledger init .nightshift/runs/sbx-12/ledger.yaml --id sbx-12 --project nightshift-sandbox --issue 12 --branch plan/sbx-12
```

### get

```
ns-ledger get <ledger> [jq-filter]
```

Prints the ledger as JSON, or `jq -r <filter>` of it.

```
ns-ledger get "$NS_LEDGER" '.budget.used'
```

### set

```
ns-ledger set <ledger> <jq-program>
```

Applies the jq program to the ledger, sets `updated`, validates and writes. If the result is invalid it exits 1 with `ledger <path>: <first error>; not written`.

```
ns-ledger set "$NS_LEDGER" '.step = "phases" | .feature_branch = "feature/12"'
```

### event

```
ns-ledger event <ledger> <type> <note>
```

Appends an event.

```
ns-ledger event "$NS_LEDGER" phase-start "p1-x attempt 1"
```

### state

```
ns-ledger state <ledger> <state> [--gate <g> | --no-gate] [--note <text>]
```

Sets the state, and the gate when given (`--no-gate` clears it), and appends a `state` event with the note `<state>[ gate <g>]: <text>`. Like `set`, it keeps the budget clock right (see [The budget clock](#the-budget-clock)).

```
ns-ledger state "$NS_LEDGER" waiting --gate 1 --note "plan ready"
```

### tier

```
ns-ledger tier <ledger> <T> --source triage|owner --hours <h> [--recommended <T>] [--tags <a,b>]
```

Sets `tier`, `tier_source` and `budget.limit`, optionally `tier_recommended` and `tags`, and appends a `tier` event.

```
ns-ledger tier "$NS_LEDGER" T2 --source triage --hours 6 --tags python,risk:policy
```

### checkpoint

```
ns-ledger checkpoint <ledger> [--push]
```

Updates the budget: if the state is `running` and the budget is not paused, `used` grows by the whole steps of 0.01 h (36 seconds) since `budget.since`, and `since` moves forward by exactly the time charged, so the remainder is carried to the next checkpoint and frequent checkpoints lose nothing; otherwise `since` is set to now (see [The budget clock](#the-budget-clock)). It then stages the ledger directory and, if anything is staged there, commits only that directory with the message `ns-ledger: <id> <state>`. Other modified files in the worktree are left alone. A commit that hits a git `index.lock` is retried three times, one second apart.

With `--push` it runs `git push -q origin HEAD:<branch>`. If the push fails it appends a `push-failed` event and still exits 0; the next checkpoint commits that event.

```
ns-ledger checkpoint "$NS_LEDGER" --push
```

### validate

```
ns-ledger validate <ledger>
```

Exits 0 if the ledger is valid (after recovery, see below), otherwise prints the problem and exits 1.

### budget-exceeded

```
ns-ledger budget-exceeded <ledger>
```

Exits 0 if `budget.limit` is set and `budget.used` has reached it (`used >= limit`), otherwise exits 1. It reads `used` as of the last checkpoint; `ns-conductor budget-check` checkpoints first and escalates.

```
ns-ledger budget-exceeded "$NS_LEDGER" && ns-ledger state "$NS_LEDGER" parked --note "budget used up"
```

## The budget clock

The clock runs while the state is `running` and `budget.paused` is false. `set` and `state` compare the ledger before and after the write: when the write stops the clock (a gate, a park, a stop, a pause) the hours since `budget.since` are added to `used` first; when it starts the clock again (back to `running`, or an unpause) `since` is set to now. So the next checkpoint never charges time spent queued, at a gate, parked, stopped or paused. A write that sets `since` itself is never charged. A crashed run is still `running`, with the old `since`: every command that moves a run with no live conductor out of that state sets `since` to now in the same write (`ns resume`, also when it has to queue the run, `ns drain` and `ns kill`), so the time it was dead is not charged either.

## Schema drift and live runs

An unknown top-level key (for example one written by a newer or older release) is not corruption: `ns-ledger get`, `ns ls`, `ns status` and `ns resume` read the ledger, print `ledger has unknown field <k>; kept` and keep the key on write. A missing required field or a wrong type is an error that names the field; run `ns-ledger validate <ledger>` to see it.

`ns-launch` exports `NS_RUN_HOME`, the home that launched the run. A command whose `NS_HOME` differs from `NS_RUN_HOME` (a different checkout) refuses to write the ledger that `NS_LEDGER` names while `NS_RUN_ID` is set, because that ledger belongs to a live run. Without `NS_RUN_HOME`, only an installed release (`NS_HOME` under `${NS_OPT:-/opt/nightshift}/`) may write it. Any other ledger (a test fixture or temp file) can still be written.

## Recovery

Every subcommand except `init` checks the file first. If it does not parse or fails the schema, `ns-ledger` reads the version committed at `HEAD` (`git show HEAD:<path>`). If that version is valid, it writes it back, appends a `recovered` event (`ledger was corrupt; restored from <short sha>`), warns on stderr and carries on. If there is no valid committed version it exits 1 with `ledger <path> is corrupt and has no valid committed version: <error>; run: ns-ledger validate <path>`.

Recovery loses only what happened since the last checkpoint, which is why the conductor checkpoints after every step.

## Rules

Never edit a ledger by hand while its run is active. A hand edit bypasses the lock and the validation, and a half-written file is exactly what recovery then throws away. To change a ledger, use `ns-ledger set` (it takes the lock).

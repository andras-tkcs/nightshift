---
name: run-ledger
description: Where a run's ledger lives, its fields and every ns-ledger subcommand; load before reading or changing run state.
user-invocable: false
---

# Run ledger

Each run has one ledger at `.nightshift/runs/<id>/ledger.yaml` in the run worktree, committed on the run branch `plan/<id>`. `$NS_LEDGER` holds its path.

Never edit it by hand. Every change goes through `ns-ledger`, which locks, validates and writes atomically.

## Fields

`id`, `project`, `request` (issue or text), `tier` (T0-T3 or null), `tier_source` (triage or owner), `tier_recommended`, `tags`, `state` (queued, running, waiting, parked, stopped, done, failed), `gate` (null, 1, 1.5, 2), `step` (intake, triage, discovery, gate1, implement, phases, board, integrate, onboard, done), `stop_requested`, `branch`, `feature_branch`, `pr`, `budget` (used, limit, paused, since; hours), `phases` (id, title, state, branch, worktree, attempts, review_rounds), `events`.

## Subcommands

- `ns-ledger init <ledger> --id <id> --project <p> --issue <n> --branch plan/<id>` creates a ledger.
- `ns-ledger get "$NS_LEDGER" .step` prints the ledger as JSON, or a jq filter of it.
- `ns-ledger set "$NS_LEDGER" '.step="triage"'` applies a jq program.
- `ns-ledger event "$NS_LEDGER" note "reconciled p1 as merged"` appends an event.
- `ns-ledger state "$NS_LEDGER" waiting --gate 1 --note "plan ready"` sets state and gate.
- `ns-ledger tier "$NS_LEDGER" T2 --source triage --hours 8 --recommended T2` sets the tier and budget.
- `ns-ledger checkpoint "$NS_LEDGER" --push` adds elapsed time to the budget and commits and pushes the ledger.
- `ns-ledger validate "$NS_LEDGER"` exits 0 when valid.
- `ns-ledger budget-exceeded "$NS_LEDGER"` exits 0 when the budget limit is passed.

## Rule

Checkpoint after each step: `ns-ledger set` the new `step`, do the work, then `ns-ledger checkpoint "$NS_LEDGER" --push`. A resumed session continues at the recorded `step`, so a step you did not checkpoint is repeated.

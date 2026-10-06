---
name: budget-guard
description: Wall-clock budgets, the review-round cap, usage-limit pauses and when to escalate to gate 1.5; load when a run nears a limit.
user-invocable: false
---

# Budget guard

## Budgets

- Wall-clock hours: `budget.limit` in the ledger, set from the profile's `budgets.<tier>.hours`. `ns-ledger checkpoint` adds the elapsed time while the state is `running` and the budget is not paused; queued, gate, parked, stopped and dead time is never charged (every way back to `running` restarts the clock). `ns-ledger budget-exceeded "$NS_LEDGER"` exits 0 once `used` reaches the limit.
- Review rounds: `ns-conductor review-round <id> <phase>` counts a round and exits 7 once the count passes `budgets.<tier>.review_rounds`.
- The time budget is enforced for you on every tier: `ns-conductor budget-check` runs inside `should-stop`, `start`, `fix-branch`, `checks`, `review-round` and `stack-base`, and in the plugin's hooks. Over budget it stops the workers, writes `RUN/escalation.md` (`# Budget exceeded`, with a `budget_hours:` line for the owner), opens gate 1.5 and exits 4. On exit 4 from any `ns-conductor` subcommand, or a tool call denied with `ns budget:`, end the session with a one-line summary: the escalation is already done. Do not write another escalation and never change `budget.limit` yourself; the owner raises `budget_hours` and `ns approve` sets it.

## Usage-limit pause (R-BUD-2)

A usage-limit pause does not count against wall-clock budgets.

- `ns-conductor wait` detects a worker that hit a usage limit, prints `finished <phase> usage-limit`, sets the budget paused and returns the phase to `pending`.
- Keep calling `ns-conductor wait <id> --timeout 540` until `ns-conductor start` succeeds for that phase, then `ns-conductor unpause <id>`.
- `ns-conductor pause <id>` and `ns-conductor unpause <id>` set the pause by hand when needed.

## When to escalate to gate 1.5 (R-BUD-1)

Escalate when the review-round cap is hit (exit 7), a phase fails twice, a worker reports `blocked` on an open decision, or auto permission mode is unavailable (`start` exit 5). The time budget escalates itself (exit 4, above).

1. Write `RUN/escalation.md`: what is stuck, what was tried, the question, and an empty `## Owner's answer` section.
2. Run `ns-conductor gate <id> 1.5 RUN/escalation.md`.
3. End the session. After `ns approve` the resumed session reads the answer and continues.

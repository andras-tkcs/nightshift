---
name: budget-guard
description: Wall-clock budgets, the review-round cap, usage-limit pauses and when to escalate to gate 1.5; load when a run nears a limit.
user-invocable: false
---

# Budget guard

## Budgets

- Wall-clock hours: `budget.limit` in the ledger, set from the profile's `budgets.<tier>.hours`. `ns-ledger checkpoint` adds the elapsed time while the state is `running` and the budget is not paused. Test with `ns-ledger budget-exceeded "$NS_LEDGER"` (exit 0 means exceeded).
- Review rounds: after each review, `ns-conductor review-round <id> <phase> <approve|changes>` counts the round. The cap `budgets.<tier>.review_rounds` is the number of reviews that may run: an `approve` always proceeds, and `changes` on the last allowed round exits 7 instead of starting another worker and review.
- `ns-conductor start` exits 4 when the budget is exceeded.

## Usage-limit pause (R-BUD-2)

A usage-limit pause does not count against wall-clock budgets.

- `ns-conductor wait` detects a worker whose final result is an error caused by a usage or rate limit (a successful report that merely mentions a rate limiter does not count), prints `finished <phase> usage-limit`, sets the budget paused and returns the phase to `pending`.
- Keep calling `ns-conductor wait <id> --timeout 540` until `ns-conductor start` succeeds for that phase, then `ns-conductor unpause <id>`.
- `ns-conductor pause <id>` and `ns-conductor unpause <id>` set the pause by hand when needed.

## When to escalate to gate 1.5 (R-BUD-1)

Escalate when the time budget is exceeded, the review-round cap is hit (exit 7), a phase fails twice, a worker reports `blocked` on an open decision, or auto permission mode is unavailable (`start` exit 5).

1. Write `RUN/escalation.md`: what is stuck, what was tried, the question, and an empty `## Owner's answer` section.
2. Run `ns-conductor gate <id> 1.5 RUN/escalation.md`.
3. End the session. After `ns approve` the resumed session reads the answer and continues.

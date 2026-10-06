---
name: budget-guard
description: Wall-clock budgets, the review-round cap, usage-limit pauses and when to escalate to gate 1.5; load when a run nears a limit.
user-invocable: false
---

# Budget guard

## Budgets

- Wall-clock hours: `budget.limit` in the ledger, set from the profile's `budgets.<tier>.hours`. `ns-ledger checkpoint` adds the elapsed time while the state is `running` and the budget is not paused. Test with `ns-ledger budget-exceeded "$NS_LEDGER"` (exit 0 means exceeded).
- Review rounds: after each review, `ns-conductor review-round <id> <phase> <approve|changes>` counts the round. The cap `budgets.<tier>.review_rounds` is the number of reviews that may run: an `approve` always proceeds, and `changes` on the last allowed round exits 7 instead of starting another worker and review. After the owner lets the run continue past gate 1.5, every further `changes` exits 7 again.
- `ns-conductor start` exits 4 when the budget is exceeded.

## Usage-limit pause (R-BUD-2)

A usage-limit pause does not count against wall-clock budgets.

- `ns-conductor wait` prints `finished <phase> usage-limit until <time>` when a worker's final result is a usage-limit error (a report that merely mentions a rate limiter does not count). It has paused the budget until that time and returned the phase to `pending`; `ns-conductor start` exits 8 until then.
- Do not wait in the session. Keep calling `ns-conductor wait <id>` only while other workers are still running (handle their results as usual; do not start new phases), then `ns-conductor park <id>` and end the session. `ns health-check` resumes the run after the reset time; the resumed session restarts the pending phases and then runs `ns-conductor unpause <id>`.
- `finished <phase> usage-limit escalate: <reason>` (a limit that does not reset, such as a spend limit or no usage credits, or the fourth limit of one phase): escalate to gate 1.5.
- `finished <phase> transient retry at <time>` (a capacity 429 or a 529 overload): call `ns-conductor wait <id>` again; with no worker left it sleeps until the retry is due and prints `retry <phase>`; then `ns-conductor start <id> <phase>`. A second transient error of the phase is a normal finish.
- `ns-conductor pause <id>` and `ns-conductor unpause <id>` set the pause by hand when needed.

## When to escalate to gate 1.5 (R-BUD-1)

Escalate when the time budget is exceeded, the review-round cap is hit (exit 7), a phase fails twice, a worker reports `blocked` on an open decision, or auto permission mode is unavailable (`start` exit 5), or `wait` prints `usage-limit escalate`.

1. Write `RUN/escalation.md`: what is stuck, what was tried, the question, and an empty `## Owner's answer` section.
2. Run `ns-conductor gate <id> 1.5 RUN/escalation.md`.
3. End the session. After `ns approve` the resumed session reads the answer and continues.

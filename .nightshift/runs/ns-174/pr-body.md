## Summary
Conductor overhead, part 1 of #169 (issue #174): the conductor waits through the Agent return or task notification and `ns-conductor wait`, never with fetch, sleep or file-poll loops; runs no tests, checks or edits in a worktree while an implementer works there; skips `ns:triage` when the owner gave the tier. New `ns-conductor risk-check <id>` runs at Sync and records tags, `risk_floor` and (only when above the owner's tier) `tier_recommended`. A checks cache hit appends `== cached <UTC>`. The run report Summary gains a `Full suite runs` row. docs/conductor.md now uses the exact ns-notify wording of run step 2a.

## Checks
| Check | Result |
|---|---|
| python lint | PASS |
| python test | PASS |

## Non-blocking findings and open items
- Proof step still open: one T1 run on ns-main after the release must show the reduced overhead (one full suite run, no polling loops).

## Follow-ups
- stack-base conflict with fix/ns-156 (CHANGELOG.md, bin/lib/report_logs.py, tests/bats/report.bats) was resolved by the integrator, keeping both sides.

## Manual verification
- [ ] Proof step: one T1 run on ns-main after release.

## Stack
Base is `fix/ns-156` (stacked on its PR). Conflicts resolved, both behaviours kept: `CHANGELOG.md`, `bin/lib/report_logs.py`, `tests/bats/report.bats`.

## Run report
`.nightshift/runs/ns-174/run-report.md` on the plan branch `plan/ns-174`.

## Desk link
Published by `ns-conductor finish`; see `ns status ns-174`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

tier: T2
size_tier: T2
risk_floor: none
tags: [python, jq, bash, docs]
budget_hours: 8
summary: Fix run-report and ns log gaps from run ns-x4 (real event times, step-based timeline, partial token totals, integrator subagent time, new Checks breakdown)

## Reasons

- Size: five separate behaviour changes across bin/lib/report.jq, bin/lib/report_logs.py, ns-log.sh and ns-report.sh, plus new fixture-based tests in tests/bats/report.bats and run-report docs. That is several modules, one new report section (Checks) and a new "partial" marker, so more than a T1 bug fix.
- Unknowns: modest. The timeline, usage fallback and subagent time need the ns-x4 log shapes, but no research or ADR.
- Risk: no match with the profile risk_zones (plugins/ns/hooks/**, bin/lib/config.sh, bin/ns-launch). No platform_paths and no invariant or trust boundary at stake. The change only reads logs and ledger. Floor is none.
- Stack: bin/lib/report_logs.py matches the python stack path. The profile lists no specialists.
- Not lower than T2: the new public report output (Checks section, partial totals) and the docs update.
- Not higher than T2: one area, probably 1 to 3 phases, no new trust boundary.
- The profile has no `budgets` section, so budget_hours uses the rubric default for T2 (8).

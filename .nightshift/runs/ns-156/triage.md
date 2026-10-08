tier: T1
size_tier: T1
risk_floor: none
tags: [python, jq, bash, bats, docs]
budget_hours: 2
summary: Run report starts a dead gap at the last conductor log activity instead of the previous ledger event, when logs exist
## Reasons
- Size: a bug fix in a few files: bin/lib/report.jq (the $dead binding, lines 47-49), probably bin/lib/report_logs.py (emit the last activity time) and bin/lib/ns-report.sh (plumbing), plus a reproducing case in tests/bats/report.bats and a docs note. Roughly 4 to 5 files, about 960 lines in the area.
- No new public surface and no new CLI flag. The fix is a clear rule: with logs, the gap starts at the last assistant/user timestamp before the resume; without logs, keep the ledger-only rule.
- Risk: none of the profile's risk zones match (plugins/ns/hooks/**, bin/lib/config.sh, bin/ns-launch). No platform paths. No invariant or trust boundary is touched. The report is a read-only calculation.
- Why not T0: it spans jq, Python and shell, and it needs a test and a docs update.
- Why not T2: no feature, no new surface, and one phase is enough.
- The profile has no `budgets` section, so budget_hours is the rubric default for T1 (2 hours).
- Tags: the python stack matches bin/lib/*.py (report_logs.py).

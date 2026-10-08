## Summary
`ns report`: the dead gap now starts at the last log activity instead of the previous ledger event (changes in `bin/lib/report.jq`, `bin/lib/report_logs.py`, docs/usage.md, CHANGELOG.md; test in `tests/bats/report.bats`).

## Checks
| Check | Result |
|---|---|
| python lint | PASS |
| python test | PASS |

## Non-blocking findings
- `report_logs.py:46`: the module-level `ACTIVITY` set is filled as a side effect in `read_session_log`; cleaner to return the timestamps.
- `report.bats`: no test for log activity before the previous ledger event.

## Run report
`RUN/run-report.md` on the plan branch (published by `ns-conductor finish`).

Fixes #156

🤖 Generated with [Claude Code](https://claude.com/claude-code)

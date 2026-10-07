## Summary

Fixes gaps in the run report and `ns log` (run ns-x6, tier T1). Triage recommended T2; the owner set T1.

- Step events are recorded on `ns-ledger set`, and the report shows them.
- The `ns-conductor checks` log is now appended to, one `== run <UTC time>` line per run. The report's Checks table uses the last run and the Checks breakdown uses every run.
- A cut-off Agent call with no tool result takes its time from the latest assistant message.
- A model with only partial tokens gets cost `no data`.
- `stream-view.py` converts timestamps to UTC.
- Docs updated: docs/conductor.md, docs/ledger.md, docs/usage.md.

## Checks

| Check | Result | Detail |
|---|---|---|
| `tests/lint` | PASS | |
| `bats --jobs "$(nproc)" tests/bats` | FAIL (1, pre-existing) | Full suite ran with one failure: bootstrap.bats 'step 1 with a failing apt-get'. It also fails on origin/main and is unrelated. Recorded as a follow-up. Not rerun at integrate (machine load about 35 from other runs). |
| Conditional and judgement rows | n/a | the profile has no `docs.dod` |

## Notes for the reviewer

- `bin/lib/profile.sh` and `bin/ns-ledger` are outside the mini-plan's Files list but were needed (step events, appended checks log).
- The partial-token fallback applies only when a log has no result event at all. This is narrower than mini-plan item 3; docs/usage.md says so.
- The latest-message time for a cut-off Agent call is per log, not per session. If a later session follows in the same log, the time can run into it.
- The checks log grows for the life of a run.
- The tests for step events, the last-run Checks table and the two `== run` lines are in cf26c0f, after the fix commit. They are not failing-first tests. The cut-off Agent call test (d51be51) did come first.
- Review round 2: approve, no blocking findings. Non-blocking: a duplicate `<target>.checks.log` row in the docs/conductor.md log table (already on main).

## Follow-ups

- bootstrap.bats 'step 1 with a failing apt-get' fails on origin/main on ns-main too (pre-existing, unrelated to ns-x6); it was the only failing test in the full suite.

## Manual verification

None.

## Stack

Base `main`; no other run PR is open.

## Run report

`.nightshift/runs/ns-x6/run-report.md` on branch `plan/ns-x6` (`ns-conductor finish` rewrites and publishes it).

## Desk link

Published by `ns-conductor finish`; see `ns status ns-x6`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

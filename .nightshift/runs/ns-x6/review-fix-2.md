# Review ns-x6 fix, round 2

Range: `origin/main...origin/fix/ns-x6`, head 73cea2ce4dffa318e8a57f08d8fe69a295da9e92. Checked against the mini-plan, CLAUDE.md and .claude/project-profile.yaml. I ran only tests/bats/report.bats, stream.bats and ledger*.bats (all pass), plus one probe of `read_checks_log` on a log that mixes an old-format run with a new `== run` run (the last run is picked correctly).

## Findings

- blocking · docs/conductor.md:145 · Still says the checks log is "rewritten on each run, so it holds the last run for that target". `ns_profile_checks_run` now appends, and each run starts with `== run <UTC>`. · Say that the log is appended to, that each run opens with `== run <UTC>`, and that `ns report` takes its Checks table from the last run and its Checks breakdown from all runs.
- blocking · docs/conductor.md:269 · The logs table still describes `<target>.checks.log` as "the last `checks` run for a phase or `feature`". · Change it to "every `checks` run for a phase or `feature`, each opening with `== run <UTC>`".
- blocking · bin/ns-ledger:139-140, bin/lib/profile.sh:40-41, bin/lib/report_logs.py:316-343 · Two new behaviours have no test. (1) `ns-ledger set` appending a `step` event when `.step` changes. Real T0/T1 runs need it to get a step timeline, and the report test uses a hand-written ledger. (2) The checks log appending with `== run` markers, and the Checks table keeping only the last run (`last`). The ns-x6 checks fixtures have no `== run` lines. · Add bats tests that fail without the change. In ledger.bats: `set '.step="triage"'` adds one `type: step, note: triage` event, and a set that leaves `.step` alone adds none. In report.bats: a checks log with two `== run` blocks lists only the second block in the Checks table, and the breakdown counts both. Optionally add a conductor-loop test that two `checks` runs leave two `== run` lines.
- non-blocking · docs/ledger.md:46 · The list of event types in use does not include the new `step` type. · Add `step` (note: the new step) to the list.
- non-blocking · bin/lib/report_logs.py:281 · When a log has no result event, its partial tokens go into `models` with cost 0.0, so the By model table shows `$0.00` for that model instead of `no data`. · Keep that model's cost as None (or flag it as partial) so `money` prints `no data`.
- non-blocking · bin/lib/profile.sh:41 · `<target>.checks.log` now grows without limit for the life of the run. This is acceptable for one run's logs. · Mention it in the PR body as a possible follow-up (rotation) if logs get large.

## Summary

The mini-plan's five fixes are in place and their fixtures and tests are in the failing-test commit cd32e47. `ns log` uses each event's own timestamp. The T0/T1 timeline follows `step` events. A log without results gives partial tokens. Foreground subagent time comes from the Agent call to its tool_result, and background launches are excluded. The Checks breakdown is a new table. `expected.md` changed in the fix commit only to add the new breakdown section, which is legitimate. The code looks correct.

The blocking items are a stale description of the checks log in docs/conductor.md and missing tests for the two supporting changes: the step event in `ns-ledger set`, and the appended checks log with its last-run selection. Nothing was copied from untrusted text, and the diff contains no `.nightshift/` files or secrets.

REVIEW verdict=changes head=73cea2ce4dffa318e8a57f08d8fe69a295da9e92

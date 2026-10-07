# Review ns-x6 fix, round 1

Range: `origin/main...origin/fix/ns-x6` (commits cd32e47 test, 73cea2c fix). Checks not run, as the caller asked.

## Findings

- blocking · docs/conductor.md:145 and docs/conductor.md:269 · `ns_profile_checks_run` now appends to `<target>.checks.log` and opens each run with `== run <UTC>` (bin/lib/profile.sh:40-41), but conductor.md still says the log is "rewritten on each run, so it holds the last run for that target", and the log table says "the last `checks` run". The diff does not update this doc. · Update both places: the log is appended to, each run opens with `== run <UTC>`, `ns report` shows the last run in Checks and all runs in Checks breakdown.
- blocking · bin/lib/report_logs.py:206-221 · Mini-plan item 4 says to fall back to the Agent tool_use and tool_result timestamps, "or to the last assistant message of the session". Only the first fallback is in the diff. An Agent call that was cut off (no tool_result; it gets added in the loop at 206-209) still shows `no data` for time. The plan names that case ("foreground or cut off"). · When there is no tool_result for a non-launched Agent call, use the latest assistant-message timestamp in the session after `use_t[tid]`. Add a fixture and test for it in a `test:` commit before the fix, and update the Subagents sentence in docs/usage.md.
- non-blocking · docs/ledger.md:46 · The list "the types in use are ..." does not include the new `step` event type, although line 88 documents it. · Add `step` (note: the new step) to the list.
- non-blocking · bin/lib/report_logs.py:280-282 · Partial-only models are added with `cost: 0.0`, so the By model table shows `$0.00` for a model whose cost is unknown, not `no data`. · Mark partial-only model cost as None, or render it as `no data`.
- non-blocking · bin/lib/report_logs.py:277 · The fallback only applies when the log has no result event at all (`not sessions`). A log where one session has a result and another session was cut off still drops the cut-off session's tokens from the totals. This matches the docs, but it is narrower than mini-plan item 3. · If that is intended, leave it and say so in the PR body. Otherwise make the fallback per session.
- non-blocking · bin/lib/stream-view.py:13-14 · `ts[11:16]` assumes a UTC `Z` timestamp. A timestamp with an offset would show local wall time, while the fallback shows UTC. · Parse with `datetime.fromisoformat` and convert to UTC, or accept this because Claude Code writes `Z`.
- non-blocking · bin/lib/profile.sh, bin/ns-ledger · Both files are outside the mini-plan's Files list. Items 2 and 5 need them, and the plan anticipates docs/ledger.md changing for step events, so they are justified. · Mention them in the PR body.

## Summary

The diff covers the five mini-plan items. `ns log` uses each event's timestamp. T0 and T1 timelines come from `step` events, which `ns-ledger set` now writes. Cut-off logs give partial tokens. A foreground subagent's time comes from its Agent call to its tool result. A new Checks breakdown table counts every run. The failing tests are in their own commit before the fix, and no existing test is weakened: the expected.md change only adds the new section. Untrusted text was not copied into code, docs or tests, and no `.nightshift/` files are on the branch. Two findings are blocking. docs/conductor.md still describes the old rewrite-on-each-run checks log. The plan's second fallback for subagent time, for a cut-off Agent call with no tool result, is missing and has no test.

REVIEW verdict=changes head=73cea2ce4dffa318e8a57f08d8fe69a295da9e92

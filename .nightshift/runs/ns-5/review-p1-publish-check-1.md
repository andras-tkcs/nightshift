# Review: ns-5 phase p1-publish-check, round 1

Range: `git diff origin/feature/5...origin/feature/5--p1-publish-check` (one commit, 673c13f)
Plan: `docs/ns-5-plan.md`, phase `p1-publish-check` (D-check, D-message, D-tests)

## Findings

- non-blocking · tests/bats/desk.bats:49 · The diff also deletes the `ns_xfail` helper. The brief does not mention this, but the helper's own comment says the implementing phase removes the `ns_xfail "ns:ns-5 acceptance"` prefixes in the same commit as the code. Nothing else uses it. · No change needed. Note it in the PR body so a reader sees that the expected-failure markers were retired on purpose and the tests were not weakened.

No blocking findings.

## Summary

- Correctness: `ns_desk_check_html` in `bin/lib/desk.sh` is character-for-character the same as the D-check block (checked by diffing it against plan lines 28-67). `ns_desk_run_dir` and `ns_desk_index` are unchanged. The check fails closed: any grep exit code other than 1 refuses, and the NUL pre-check runs before the grep loop.
- `bin/lib/ns-publish.sh`: only the message line changed, and it now matches D-message. `no external scripts or styles` has 0 hits in both `ns-publish.sh` and `desk.bats`.
- Tests: every D-tests case is present with its exact name and body. The four `issue #5 bypass` cases are counted (grep prints 4). The base branch already had the acceptance tests under strict xfail, and this phase removes the markers together with the code. No assertion was loosened. The line-64 (now line 81) assertion was changed to the new text as the plan says.
- Scope: only the three files in `touches` changed. No docs, CHANGELOG, Caddy template or `.nightshift/` files. The commit message matches the brief.
- Untrusted text (R-SEC-3): the test inputs are the bypass payloads that the plan's D-tests table specifies. They are refusal fixtures and are not run. Nothing was copied in as instructions.
- I did not run the checks: `bats`, `tests/lint` and the AC-1 negative check (step 7). The caller did not ask for them. The orchestrator should confirm the phase acceptance commands and the worker's step-7 "not ok" lines.

REVIEW verdict=approve

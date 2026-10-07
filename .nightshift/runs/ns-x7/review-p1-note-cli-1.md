# Review p1-note-cli, round 1

Range: `origin/feature/x7...origin/feature/x7--p1-note-cli` (1 commit, 6cc7242). Plan: docs/ns-x7-plan.md, phase p1-note-cli, D1/D2/D3/D6/D7. Project checks were not run (caller did not ask); the review is of the diff only.

## Findings

- blocking · tests/bats/note.bats:65 (`x7_note_push_fails`) · The implementation commit deletes the assertion `[ -z "$(git -C "$WT" status --porcelain -- .nightshift)" ]` from the pre-existing AC-1 push-failure acceptance test (base tests/bats/note.bats:80). This weakens a test to get it green: `ns-ledger checkpoint --push` (bin/ns-ledger:224-227) writes the `push-failed` event after the commit and never commits it, so the worktree is dirty after a failed push and the assertion cannot pass with D1 as designed. The brief said to remove only the `ns_xfail` prefixes and the helper. · Restore the assertion. The fix is outside this phase's `touches` (bin/ns-ledger), so stop with status=blocked and escalate. Then either the planner amends the test strategy or acceptance in a separate, reviewed change that drops the clean-tree requirement for the push-failed case, with a reason (AC-1 does not require a clean tree after a failed push), or a phase that may touch bin/ns-ledger commits the push-failed event. Do not delete the assertion silently.
- non-blocking · bin/lib/ns-note.sh:27 · The note text goes into the `ns-ledger set` program as one argv element, so a very large note (about 128 KiB, MAX_ARG_STRLEN) fails with E2BIG and an unclear error. · Later work: cap the note length with a clear message, or add `--arg` support to `ns-ledger set` (the plan rejected that for now).
- non-blocking · bin/ns-conductor:696 · `owner-notes` folds only CR/LF. Other control characters in a note (for example ESC) reach the conductor's terminal output unchanged. · Later work: also replace `[[:cntrl:]]` with a space.

## Checks done

- Scope: all 10 changed files are in the phase's `touches`. There are no `.nightshift/` files, no secrets and no stray files.
- Design conformance: ns-note.sh matches D1 step for step. The schema property matches D2 and sits after `stop_requested`, outside `required`. conductor_owner_notes, the usage line and the dispatch match D3. The report block matches D6 and comes before Timeline. The docs/usage.md, docs/ledger.md and docs/conductor.md texts match D7.
- Shell safety of the note text: `jq -cn --arg t "$text" '$t'` makes a JSON string, and that string is spliced into the program as a jq string literal. `"`, `\`, `\(` and `$now` are escaped or inert inside a literal, so nothing is interpolated. There is no `eval` and no unquoted expansion. In owner-notes only `${idx}` is interpolated, and it is a jq-generated array of integers. Test 5c (`x7_note_safe_text`) covers the round trip.
- Tests: apart from the finding above, the diff only removes the `ns_xfail` wrapper and helper, as the brief told it to. The ledger.bats and report.bats tests are unchanged except for the unwrap. No skip or expected-failure marker remains. The tests were added failing first in the base (0dc798e, as xfail).
- Acceptance evidence: AC-1, AC-2 and AC-5 are covered by note.bats tests (the AC-1 push-failure case is weakened, see above). AC-3 is covered by four ledger.bats tests and AC-7 by a report.bats test. The schema and docs grep items are satisfied by the diff. Lint, the full bats suite and docs-check were not run by this review.
- Untrusted text (R-SEC-3): no command, URL or instruction from untrusted text appears in the diff.

## Summary

The implementation follows D1, D2, D3, D6 and D7 exactly and handles the note text safely. One blocking issue: an assertion was deleted from an existing acceptance test (the clean worktree after a failed push) because the designed behaviour cannot meet it. That needs an escalation and an explicit decision, not a silent deletion.

REVIEW verdict=changes head=6cc724233a708aab7ce3b42797d7c4010b1970e8

## Summary

Fixes #166. The handoff report is now published as Markdown (`handoff.md`, from `template.md`) so it renders on the desk. `conductor_finish` publishes it with the same fatal-on-failure path as #118; `ns approve` skips the read-only `handoff.md`. Integrator, run, review and review-desk skills, e2e scenarios, spec R-DSK-1, docs and CHANGELOG are updated.

## Checks

| Check | Result | Detail |
|---|---|---|
| python lint | PASS | |
| python test | FAIL (unrelated) | Only `kill.bats` "ns_kill_group gives up after about 2 s" (#58) failed under full-suite load (>5 s wall clock); it passes when run alone. |
| judgement rows | n/a | profile has no docs.dod |

## Non-blocking findings (review-fix-1, verdict approve)

- tests/bats/approve.bats:85-91: the "approve never commits a desk-edited handoff.md" assertion was added in the fix commit, not the test-first commit, so its fail-first is not in history. The reviewer checked it against the pre-fix `ns-approve.sh`: it would have failed there, so the test is real.
- tests/bats/desk.bats:196: the deleted "filled handoff template passes the check" test has no Markdown replacement; add a test that fills template.md and runs `ns publish`.
- plugins/ns/skills/handoff-report/SKILL.md:23: "no HTML" rule has no self-check; add `grep -cE '<[A-Za-z/!]' RUN/handoff.md` prints 0.
- docs/architecture.html:843: still names "integrator, architect" as writers; change to "architect".
- bin/lib/ns-approve.sh:16: help line is about 110 columns; re-wrap.
- docs/usage.md:304: say approve prints diffs "except handoff.md".
- tests/bats/conductor-loop.bats:860: build the `ghp_` token-shaped string at runtime as desk.bats `tok()` does.

## Follow-ups

- kill.bats 'ns_kill_group gives up after about 2 s' (#58) fails under full-suite load (>5 s wall clock), passes alone; unrelated to ns-166.

## Stack

Base `main`; not stacked.

## Run report

`.nightshift/runs/ns-166/run-report.md` on branch `plan/ns-166`; `ns-conductor finish` publishes it.

## Desk link

Published by `ns status ns-166` / the run's desk page.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

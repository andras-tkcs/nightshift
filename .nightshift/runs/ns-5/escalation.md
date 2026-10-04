# Escalation: ns-5, phase p1-publish-check

## What is stuck
Phase `p1-publish-check` is approved by the reviewer (`review-p1-publish-check-1.md`, verdict approve) and `ns-conductor report` is OK (head 673c13f). `ns-conductor checks ns-5 p1-publish-check` exits 1 for one reason only: `FAIL python test`. `PASS python lint` and the whole bats suite (339 cases) are `ok`, with no `not ok`.

## Cause
The `python test` check runs `pytest` from the repo root. It collects `tests/fixtures/sandbox-base/tests/test_numbers.py` and `test_text.py`, which import `sandbox_pkg`. That package is not installed, so collection fails with ModuleNotFoundError. The same failure happens on `origin/feature/5` without the phase. The phase touches only `bin/lib/desk.sh`, `bin/lib/ns-publish.sh` and `tests/bats/desk.bats`.

## What was tried
Re-ran the checks once with full output to confirm. I did not skip, edit or override the check, and I did not merge.

## Question
How should the gate treat this? Options:
1. Accept the python check as a pre-existing, unrelated failure and tell me to merge the phase.
2. Have the profile or stack scoped so pytest ignores `tests/fixtures` (a separate change, outside this plan).

## Owner's answer

Create an issue for it and continue, merge the phase


---
# Escalation 2: merge refused

Owner answer was: file an issue, continue, merge the phase.
- The issue was NOT created: the auto-mode classifier denied `gh issue create` (external write). Please file it yourself. Suggested title: "pytest at repo root collects tests/fixtures/sandbox-base and fails (sandbox_pkg not installed)".
- `ns-conductor merge ns-5 p1-publish-check` re-runs the checks and exits 1 on the same pre-existing `FAIL python test` (bats 339 ok). The phase stays in `review`. I will not merge by hand around the conductor.

## Question
Pick one: (a) merge `feature/5--p1-publish-check` into `feature/5` yourself (or tell me to do it with plain git), or (b) scope pytest to ignore `tests/fixtures` first, then I re-run merge.

## Owner's answer

B


---
# Escalation 3: scoping pytest is not enough

Owner answer was B (scope pytest away from `tests/fixtures`).
- Done: committed `pytest.ini` (`norecursedirs = tests/fixtures ...`) on `feature/5--p1-publish-check` (847ed62) and pushed. Collection errors are gone.
- Result: `ns-conductor checks ns-5 p1-publish-check` still reports `FAIL python test`. This repo has no Python tests outside the fixtures, so `pytest -q` exits 5 ("no tests ran"). `PASS python lint`, bats ok.
- Not done: I did not add a placeholder test or edit the stack/profile to skip the check, as either weakens or sidesteps a check.

## Question
Pick one: (a) the python stack should not apply to this repo (remove or override `test` in the project profile, a change outside this plan); (b) allow a trivial placeholder Python test in this repo; (c) merge `feature/5--p1-publish-check` yourself with plain git.

## Owner's answer

I revise my previous decision fix this python issue as it become blocker


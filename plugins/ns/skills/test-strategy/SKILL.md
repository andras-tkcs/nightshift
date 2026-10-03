---
name: test-strategy
description: Acceptance-test-first workflow, the test pyramid, expected-failure markers and the rule never to weaken a test; load when planning or writing tests for a run.
user-invocable: false
---

# Test strategy

## Acceptance tests first

1. Start from the numbered criteria in `RUN/acceptance.md`. Each `AC-<n>` needs a test or a named command with an expected result.
2. Write the acceptance tests before any implementation, as expected failures: Python `pytest.mark.xfail(strict=True, reason="ns:<id> acceptance")`; other frameworks their expected-failure marker with the same reason text.
3. Run the checks and confirm each new test is reported as an expected failure, not as an error and not as a pass. A strict xfail that passes is reported as a failure, which tells you the test proves nothing.
4. Commit tests only, on `plan/<id>`, as `test: acceptance tests for <id>`.

## The pyramid

- Many unit tests: fast, one behaviour each, no network or clock.
- Some integration tests: real files, real subprocesses, fake remotes.
- Few end-to-end tests: the whole path, against the sandbox only; slow, so one per user-visible flow.

Prove each criterion at the lowest level that can show it. Fixtures are small, checked in, and built by a helper rather than copied by hand.

## Rules

- Never weaken a test to make it pass: do not loosen an assertion, delete a case, add a skip or widen a tolerance. If a test is wrong, say so in the report and change it in its own commit with the reason.
- The phase that implements a criterion removes the expected-failure markers of exactly its tests, in the same commit as the implementation. Leftover markers on passing code are a review finding.
- A test must fail for the right reason: the assertion about the missing behaviour, not an import error or a typo.
- Keep tests deterministic: no sleeps for synchronisation, no dependence on test order.
- `RUN/test-strategy.md` records the mapping `AC-<n>` to test, the pyramid split and the fixtures.

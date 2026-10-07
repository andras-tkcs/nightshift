## Summary

Renames `ns health-check` to `ns check`. `ns health-check` still works as a deprecated alias. The `ns-health.*` systemd units keep their names and now run `ns check`. Docs, skills, schema, tests and CHANGELOG are updated.

## Checks

| Check | Result |
|---|---|
| `tests/lint` | PASS |
| `bats tests/bats` | FAIL on 1 test, environmental (see below); all others pass |
| `tests/docs-check --final` | PASS |

## Non-blocking findings and open items

- `tests/bats/bootstrap.bats` "step 1 with a failing apt-get does not report changed and exits non-zero" fails on the base branch too (environmental), not caused by this change.
- The implementer did not run `tests/lint`; it was run at integration and passes.

## Stack

Base `main`; no other run PR was open. origin/main was merged in; the only conflict was CHANGELOG.md (both `[Unreleased]` entries kept).

## Run report

`ns-conductor finish` publishes the run report (`RUN/run-report.md`).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

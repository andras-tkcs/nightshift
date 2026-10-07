## Summary

ns-x5 (T2): `ns-conductor checks` gets a per-target lock, a result cache keyed by tree and checks list, `--force`, a canonical target (`fix` counts as `feature` on T0/T1) and a warning when the worktree lacks the run's pushed code. `stack-base` now fetches, merges the top run PR's branch and pushes. Workers run only the touched tests; the full suite runs once through `ns-conductor checks`. Docs, skills and the changelog are updated.

## Phases

| Phase | Merge commit | Status |
|---|---|---|
| p1-checks-cache | ad83b35 | merged |
| p2-stack-base-flow | 8d6c04d | merged |
| p3-retire | 852727e | merged |

## Checks

| Check | Result |
|---|---|
| python lint | PASS |
| python test (full bats suite via `ns-conductor checks ns-x5 feature`) | PASS |

Known, owner-accepted failures seen earlier in the run: bootstrap.bats #32 (no sudo on ns-main; also fails on origin/main) and kill.bats #464 (flaky under full-suite load). They did not fail in the final runs and are not counted as passes. No SKIP rows. Details: RUN/dod.md.

## Non-blocking findings and open items

From the code board (`board-code.md`), no blocking findings:
- bin/lib/conductor-loop.sh:387: `ns_die` in `loop_checks_key` exits only the command substitution; use `key=$(...) || exit`. Safe today (never a false pass).
- bin/lib/conductor-loop.sh:161: overlong comment line.
- plugins/ns/skills/run/SKILL.md:44: T0 step 4 wording can read as a second checks run after Sync.
- docs/agents.md:85: integrator Stacking sentence splits the either/or.
- docs/conductor.md:145: "The stack merge command of `ns`" should name `ns stack merge`.
- CHANGELOG.md:18: `### Changed` sits after `### Fixed`.

## Follow-ups

- bootstrap.bats "step 1 with a failing apt-get..." fails on origin/main too (no sudo on ns-main); kill.bats "ns_kill_group gives up after about 2 s" is flaky under full-suite load.
- ns-x4 cause: T1, so `checks ns-x4 feature` already resolved to the fix worktree. Real causes: checks ran before the round-1 review fix commits and were not rerun; the integrator ran `checks ns-x4 fix` separately; implementers and the integrator ran bats directly 6+ times in overlap, and /ns:dod ran it again.
- Board non-blocking items above (note 3); lock tests were lengthened from `sleep 3` to `sleep 10` during the run (now a release file, see Stack), and the stack-pr test gained a running-ledger fixture.

## Manual verification

None (`manual_after` is empty).

## Stack

Stacked on ns-x9 (`fix/ns-x9`). `ns-conductor stack-base` merged it into `feature/x5` with conflicts, resolved by hand:
- docs/conductor.md: kept ns-x5's checks text and took ns-x9's append-log wording (`== run` lines, Checks breakdown) in the `checks` section and the logs table.
- tests/bats/conductor-loop.bats: kept both sets of tests. The ns-x6 "two == run lines" test now passes `--force` on the second call, since ns-x5's cache would otherwise skip it. The ns-x5 lock tests now hold the check with a release file instead of `sleep 10`, to satisfy the suite-speed rule that arrived with the merge.

## Run report

`RUN/run-report.md` on branch `plan/ns-x5` (`ns-conductor finish` publishes the final version).

## Desk link

Published by `ns-conductor finish`; see `ns status ns-x5`.


🤖 Generated with [Claude Code](https://claude.com/claude-code)

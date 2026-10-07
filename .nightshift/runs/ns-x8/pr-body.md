## Summary

Speeds up the bats suite (ns-x8, tier T1 fix): real sleeps replaced by marker-based waits, repeated fixture setup cached once per file with per-test copies, host tools stubbed (bootstrap step 1 no longer forks per tool over /usr/bin or sees a live tmux), and a `suite-speed.bats` guard stops those patterns from coming back. No assertion was removed or weakened. Test-only change plus docs (CLAUDE.md, docs/development.md); no product behaviour touched.

## Checks

- Lint: PASS on 317d553 (`ns-conductor checks`); a1c7c39 only touches 3 test files and one doc line.
- Full bats suite: NOT rerun on the final head a1c7c39. The previous full run (head 317d553, `--jobs 4`, load 25-28) had 856 tests and 1 failure, `drain returns once a background loop parks the run` (drain-up.bats), a load-dependent race. a1c7c39 fixes it (waits for `stop_requested` instead of a fixed sleep, up to 10 s). drain-up.bats rerun alone on a1c7c39: all 11 tests pass.
- `tests/docs-check --final`: PASS.
- Review: round 1 and round 2 approved (round 2 on a1c7c39).

## Timing (bats --timing)

Not directly comparable: the before run used `--jobs 8`, the after run `--jobs 4`, and the machine was at load average 25-28 (other runs' suites) for both. The <5 min target at `--jobs 8` is NOT yet verified on a quiet machine.

| | Before (ef80642, jobs 8) | After (317d553, jobs 4) |
|---|---|---|
| Wall | 41m02.8s | 33.1 min (1987 s) |
| user | 73m41.0s | not recorded |
| sys | 23m18.4s | not recorded |
| Tests | 847, 3 failing | 856, 1 failing (flake, fixed in a1c7c39) |

### 15 slowest tests (wall seconds, under load)

| # | Before | After |
|---|---|---|
| 1 | 129.4 step 1 with a failing apt-get does not report changed (FAILED) | 58.8 ns resume --all respects max_runs |
| 2 | 118.6 ns resume --all respects max_runs | 55.7 a resumed integrate session has no exemption |
| 3 | 114.4 a resumed integrate session has no exemption | 53.7 --all resumes parked and crashed runs |
| 4 | 110.6 fourth conductor usage limit escalates | 52.4 two concurrent dequeues with one free slot |
| 5 | 110.4 --all resumes parked and crashed runs | 51.9 no tmux server inherits GH_TOKEN (#96) |
| 6 | 108.4 --all leaves owner-stopped runs alone (#96) | 51.2 fourth conductor usage limit escalates |
| 7 | 104.4 after stack-base passed, integrator checks may finish | 47.4 resume --all with more crashed runs than max_runs |
| 8 | 102.7 no tmux server inherits GH_TOKEN (#96) | 47.3 queued run created without --tier |
| 9 | 102.1 capacity 429 retried once | 47.2 approve at max_runs queues the run |
| 10 | 101.4 ns approve with raised budget_hours | 46.4 approve head A, push head B (ns-71) |
| 11 | 99.5 queued run created without --tier | 46.1 ns approve with raised budget_hours |
| 12 | 98.9 approve head A, push head B (ns-71) | 46.1 review-round records verdict and head (ns-71) |
| 13 | 98.7 usage limit without reset time backs off | 45.4 review-round: after the cap, approve exits 0 |
| 14 | 97.0 integrate exemption ends at the margin | 45.1 resume --all does not charge parked/crashed gap |
| 15 | 95.6 review-round records the verdict (ns-71) | 44.9 --yes on the sandbox project commits the edit |

### Slowest files (sum of test wall seconds, under load)

| Before | After |
|---|---|
| stack-pr 2689 s (55) | budget 1117 s (44) |
| conductor-loop 2296 s (52) | conductor-loop 946 s (52) |
| budget 2000 s (44) | stack-pr 869 s (55) |
| conductor 1584 s (36) | conductor 656 s (36) |
| rm 1391 s (28) | queue 534 s (18) |
| resume 1227 s (33) | run-new 479 s (31) |
| run-new 1074 s (31) | resume 378 s (33) |
| queue 1062 s (18) | rm 343 s (28) |
| desk 1012 s (64) | health 334 s (26) |
| health 710 s (26) | approve 329 s (11) |
| gc 702 s (20) | run-inspect 167 s (13) |
| report 367 s (19) | bootstrap 156 s (49) |
| bootstrap 354 s (42) | hooks 155 s (63) |
| kill 352 s (9) | kill 128 s (9) |
| run-inspect 327 s (13) | gc 126 s (20) |

Full tables: `.nightshift/runs/ns-x8/timing-before.md` and `timing-after.md` on the plan branch.

## Non-blocking findings and open items

From review-fix-1:
- suite-speed.bats guards for the `/usr/bin` loop and fixed `/tmp` path were added in the fix commit, not the failing-test commit; put every new guard in the `test:` commit next time.
- health.bats unbounded poll: fixed in a1c7c39 (capped at 50 x 0.1 s).
- helpers.bash stale header: fixed in a1c7c39.
- docs/development.md timing note: updated in a1c7c39.
- conductor.bats:182 and bin/lib/runs.sh:172 still match processes host-wide (`pgrep -f`); pre-existing, follow-up: use a per-test unique marker.

From review-fix-2:
- bootstrap.bats:419-420 has two comment lines saying the same thing after the merge; collapse to one.
- health.bats:365-369 poll cap has no comment saying it only prevents a hang.
- docs/development.md:18 should get a quiet-host after figure once one exists.

## Follow-ups

- Rerun `bats --timing --jobs 8 tests/bats` on a quiet machine to verify the <5 min target.

## Manual verification

- [ ] On a quiet machine, run `bats --timing --jobs 8 tests/bats` and confirm the suite is green and under 5 minutes.

## Stack

Stacked on #164 (base `feature/144`). Merged feature/144 into fix/ns-x8 (317d553); the one conflict, tests/bats/bootstrap.bats, was resolved in favour of the batched `find ... -exec ln -sf` form while keeping feature/144's tmux-stub comment.

## Run report

`.nightshift/runs/ns-x8/run-report.md` on branch `plan/ns-x8`.

## Desk link

Run files are published by `ns-conductor finish`; see `ns status ns-x8`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

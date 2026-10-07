# bats suite timing (after)

Head 317d553 (fix + merge of feature/144). Command: `bats --timing --jobs 4 tests/bats` (jobs 4, not 8, because the machine was at load 25-28 from other runs' suites; wall time is inflated and not comparable one to one with the before run).

Total wall: 1987 s (33.1 min) at --jobs 4, vs 41.0 min at --jobs 8 before. Exit 1: one failure (drain-up "drain returns once a background loop parks the run"), which passes when rerun alone.

Tests measured: 856, failing: 1

## 15 slowest tests (wall seconds, under load)

1. 58.8 s  ns resume --all respects max_runs: two start, one stays queued
2. 55.7 s  a resumed integrate session has no exemption: it is escalated over budget
3. 53.7 s  --all resumes parked and crashed runs and leaves waiting and done alone
4. 52.4 s  two concurrent dequeues with one free slot start exactly one run
5. 51.9 s  no tmux server started by ns inherits GH_TOKEN (#96)
6. 51.2 s  the fourth conductor usage limit without progress escalates to gate 1.5
7. 47.4 s  ns resume --all with more crashed runs than max_runs charges none of them the dead gap
8. 47.3 s  a queued run created without --tier (triage left it running) is queued and dequeued
9. 47.2 s  approve at max_runs queues the run: gate cleared, state queued, no session
10. 46.4 s  approve head A, push head B, report --rerun: merge refuses until a new round approves B (ns-71)
11. 46.1 s  ns approve with a raised budget_hours sets the new limit and resumes
12. 46.1 s  review-round records the verdict and the reviewed head (ns-71)
13. 45.4 s  review-round: after the cap, approve still exits 0 and changes escalates again
14. 45.1 s  ns resume --all does not charge the gap of a parked or a crashed run
15. 44.9 s  --yes on the sandbox project commits the edit, releases the gate and resumes

## Slowest files (sum of test wall seconds, under load)

- budget.bats: 1117 s over 44 tests
- conductor-loop.bats: 946 s over 52 tests
- stack-pr.bats: 869 s over 55 tests
- conductor.bats: 656 s over 36 tests
- queue.bats: 534 s over 18 tests
- run-new.bats: 479 s over 31 tests
- resume.bats: 378 s over 33 tests
- rm.bats: 343 s over 28 tests
- health.bats: 334 s over 26 tests
- approve.bats: 329 s over 11 tests
- run-inspect.bats: 167 s over 13 tests
- bootstrap.bats: 156 s over 49 tests
- hooks.bats: 155 s over 63 tests
- kill.bats: 128 s over 9 tests
- gc.bats: 126 s over 20 tests

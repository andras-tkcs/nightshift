# bats suite timing (before)

Baseline at ef80642 (before any ns-x8 change).

Command: `bats --timing --jobs 8 tests/bats` (machine shared with other suites, load average 30+; wall time is inflated, CPU time is the stable figure).

Total:
```
real	41m2.820s
user	73m40.982s
sys	23m18.420s
```

Tests measured: 847, failing: 3

## 15 slowest tests (wall seconds, under load)

1. 129.4 s  step 1 with a failing apt-get does not report changed and exits non-zero  (FAILED)
2. 118.6 s  ns resume --all respects max_runs: two start, one stays queued
3. 114.4 s  a resumed integrate session has no exemption: it is escalated over budget
4. 110.6 s  the fourth conductor usage limit without progress escalates to gate 1.5
5. 110.4 s  --all resumes parked and crashed runs and leaves waiting and done alone
6. 108.4 s  --all leaves runs stopped by the owner alone; ns resume <id> restarts them (#96)
7. 104.4 s  after stack-base passed, the integrator's checks and the hook may finish; fix-branch may not
8. 102.7 s  no tmux server started by ns inherits GH_TOKEN (#96)
9. 102.1 s  a capacity 429 is retried once after a short backoff, then takes the normal path
10. 101.4 s  ns approve with a raised budget_hours sets the new limit and resumes
11. 99.5 s  a queued run created without --tier (triage left it running) is queued and dequeued
12. 98.9 s  approve head A, push head B, report --rerun: merge refuses until a new round approves B (ns-71)
13. 98.7 s  a usage limit without a reset time backs off 15 minutes, then 30
14. 97.0 s  the integrate exemption ends at the margin: max(0.5 h, 25 % of the limit)
15. 95.6 s  review-round records the verdict and the reviewed head (ns-71)

## Slowest files (sum of test wall seconds, under load)

- stack-pr.bats: 2689 s over 55 tests
- conductor-loop.bats: 2296 s over 52 tests
- budget.bats: 2000 s over 44 tests
- conductor.bats: 1584 s over 36 tests
- rm.bats: 1391 s over 28 tests
- resume.bats: 1227 s over 33 tests
- run-new.bats: 1074 s over 31 tests
- queue.bats: 1062 s over 18 tests
- desk.bats: 1012 s over 64 tests
- health.bats: 710 s over 26 tests
- gc.bats: 702 s over 20 tests
- report.bats: 367 s over 19 tests
- bootstrap.bats: 354 s over 42 tests
- kill.bats: 352 s over 9 tests
- run-inspect.bats: 327 s over 13 tests

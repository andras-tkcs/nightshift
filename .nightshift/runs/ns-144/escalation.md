# Escalation: p1-caddy-bootstrap checks fail on the base commit too

## What is stuck
Phase p1-caddy-bootstrap is done (head 43d03d1, PHASE-REPORT status=done), but `ns-conductor checks` exits 1 for it, twice.

Failures in `bats --jobs 8 tests/bats`:
- `bootstrap.bats` "step 1 with a failing apt-get does not report changed and exits non-zero" (grep for `needs you: apt-get failed` finds nothing). I ran this single case on the base commit 6a21abd in a clean temp worktree: it fails there too. So it is not caused by the phase; it looks like a host issue (the case builds a PATH from /usr/bin without caddy on ns-main, and the host differs from what the case expects).
- `kill.bats` "ns_kill_group gives up after about 2 s ..." (#58): timing, failed once under load, not in the other run's list.

I sent the first failure back to the worker once; it changed nothing, as expected. The phase's own new cases pass.

## What was tried
Feedback round to the worker; rerun of checks; reproduction on base.

## Question
The base already fails "step 1 with a failing apt-get ..." on ns-main. Shall I review and merge p1 despite this red check (and note the failure for a separate issue), or do you want it fixed first (and in which phase)?

## Owner's answer


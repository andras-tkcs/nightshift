# Feedback for p1-caddy-bootstrap (owner decision, gate 1.5)

The owner decided: fix the failing bats case in this phase.

- `tests/bats/bootstrap.bats` "step 1 with a failing apt-get does not report changed and exits non-zero" fails on the base commit too on ns-main (grep for `needs you: apt-get failed` finds nothing). The case builds a PATH from /usr/bin without caddy; on ns-main the host differs from what the case expects. Make the case (or bootstrap step 1, whichever is wrong) robust so it passes on ns-main and in CI, without weakening what it asserts.
- `kill.bats` "ns_kill_group gives up after about 2 s" (#58) is a timing flake under load; if it fails again alone, rerun checks, do not change it.
- Run `ns-conductor checks` equivalent (bats --jobs, tests/lint) and push when green.

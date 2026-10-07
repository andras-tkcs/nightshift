# Mini-plan ns-x8: speed up the bats suite

Cause hypothesis: slow tests use real sleeps/timeouts, reach real tmux/systemctl/apt/caddy/network
through a PATH built from /usr/bin, and repeat large fixture setup per test. Unknown until measured.

Steps
1. Baseline: `bats --timing --jobs 2 tests/bats` (max 2 bats suites at once); save the 15 slowest tests
   and slowest files to RUN/timing-before.md.
2. For each slow test find the cause and fix it: stubs in a temp bin dir, fake clocks / zero sleeps via
   existing env overrides (ADR 0005), setup_file for shared fixtures. Never delete or weaken assertions.
3. Audit tests for host-state dependence (live tmux, running ns run, real caddy/apt, like bc5fdc4 in
   bootstrap.bats); stub them.
4. Parallel safety audit: no fixed /tmp paths or ports; every test uses BATS_TEST_TMPDIR / mktemp.
5. Failing test to add (step A): a bats test in tests/bats that fails today, e.g. a guard that no
   test file hardcodes a shared /tmp path or a real `sleep` over 1s, or a host-state guard that runs
   with an empty tmux/PATH. Commit `test: failing test for ns-x8`.
6. After: `bats --timing --jobs 8 tests/bats`, record RUN/timing-after.md; target < 5 min.
7. Docs: note the test conventions in CLAUDE.md/docs if affected; tests/lint and tests/docs-check pass.

Files: tests/bats/*.bats, tests/bats/helpers.bash, maybe tests/lint. Do not touch bin/ns-launch,
bin/lib/config.sh or plugins/ns/hooks/** (risk zones); escalate if a seam is needed there.
Deliverable: timings (before/after, 15 slowest, slowest files, total) in the PR body.

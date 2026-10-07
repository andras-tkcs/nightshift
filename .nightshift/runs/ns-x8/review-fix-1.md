# Review ns-x8 fix, round 1

Range: `git diff origin/main...origin/fix/ns-x8` (head 363a4fdc464f940cf0f9b1aa3d7d20da87f85ada, 2 commits: ef80642 failing test, 363a4fd fix).
Inputs: mini-plan.md, ledger request text, CLAUDE.md, docs/development.md. I did not run the project's checks because the caller did not ask for them. I was not given a worker log and did not read one.

## Findings

- non-blocking · tests/bats/suite-speed.bats:16-34 · The guards for the `/usr/bin` loop and the fixed `/tmp` path were added in the fix commit 363a4fd, not in the failing-test commit ef80642. The `/usr/bin` guard would have failed on base (bootstrap.bats had `for s in /usr/bin/*`), but the history does not show it failing first. Only the sleep guard did. · Next time, put every new guard in the `test:` commit. Nothing needs to change now because these guards check test source, not product behaviour.
- non-blocking · tests/bats/health.bats:365 · `until [ "$(ps -o etimes= -p "$CHECKS_PID" ...)" -ge 1 ]` has no bound. If the checks process dies, `ps` prints nothing, `[ "" -ge 1 ]` errors, and the test hangs forever instead of failing. · Bound it like the bootstrap loop, for example `for _ in $(seq 50); do ... && break; sleep 0.1; done`, then assert the age once after the loop.
- non-blocking · tests/bats/helpers.bash:2 · The header still says "Written in full by p01; never edited afterwards.", but this diff adds `ns_cached_fixture` to the file (the mini-plan allows that). · Update or drop the header line.
- non-blocking · docs/development.md:18 · The doc still gives the old numbers: 358 s with 8 jobs on 2026-10-06, and 20 minutes or more serial. They are dated, so not wrong, but the new suite time belongs there. · Add the after-timing from RUN/timing-after.md, with its date.
- non-blocking · tests/bats/conductor.bats:182 and bin/lib/runs.sh:172 (the latter is used by the health.bats tests) · These still look for processes host-wide (`pgrep -f "flock -w 4711 9"`, `pgrep -f "ns-conductor checks sbx-12"`). A parallel test, or another checkout's suite running at the same time, could match them. This was there before and is not part of the diff. · Follow-up: give the marker process a per-test unique string.

## Checks

- Assertions: none removed or weakened. Every `assert_*`, `[ ... ]` and `grep` assertion in the touched tests is still there. The moved setup lines are byte-for-byte the same, split into `fixture_vars` (variables) and `fixture_build` (slow, files only). `PROJ` is recomputed in setup where tests use it (drain-up, gc, rm, resume). Setup-time exports that change the build (`NS_DRAIN_POLL`, desk/gc/rm `GH_STUB_RESPONSES`) still come before the build, and stack-pr/stack-merge keep their per-test `GH_STUB_RESPONSES` after it, as before.
- Sleep replacements keep what the tests prove:
  - The busy-queue-lock test in bootstrap now holds the lock until a release marker (bounded at 30 s) instead of `sleep 6`. That is at least as strict.
  - The checks-age wait in health.bats now polls until `etimes >= 1`. With `NS_CHECKS_MAX_SECS=1`, `[ "$et" -lt "$max" ]` in runs.sh:174 then treats the check as silent, which is correct.
  - The drain-up and bootstrap in-flight waits drop from 2 s to 0.5 s, and the waiting path is still exercised.
- Parallel safety of `ns_cached_fixture`:
  - The build runs once per file under `flock` on `$BATS_FILE_TMPDIR/fixture.lock`, in a scratch dir that is renamed to `.done` only after it succeeds.
  - Every test then gets its own `cp -a` copy, and absolute paths in text files and symlinks are rewritten to its own `BATS_TEST_TMPDIR`. That covers git worktree gitdir files, remote URLs and ledgers.
  - Nothing is shared between tests, and no fixed `/tmp` paths or ports are added.
  - The cache key covers the build function body and `GH_STUB_RESPONSES`.
- Host state: the bootstrap step-1 test now links the fixture stubs (tmux, systemctl, claude, curl) last, so a live tmux session on the host can no longer block it. The per-tool fork loop over `/usr/bin` is gone, and a guard stops it from coming back.
- The request is met in the code: real sleeps are gone, repeated fixture setup is cached, and host tools are stubbed. The timing deliverable (before/after, 15 slowest, slowest files, total) goes in the PR body, which is not part of this diff, so the caller must check it there.
- Docs: CLAUDE.md now describes the conventions and the guard. No file outside the brief was touched (only tests/bats/* and CLAUDE.md), and the risk zones bin/ns-launch, bin/lib/config.sh and plugins/ns/hooks were not touched. No secrets. No `.nightshift/` files on the branch. Nothing was copied from untrusted text.

## Summary

The change is a sound per-file fixture cache with per-test copies, plus marker-based waits in place of real sleeps, and it keeps every assertion. There are no blocking findings. The five non-blocking items can go into the PR body or a follow-up.

REVIEW verdict=approve head=363a4fdc464f940cf0f9b1aa3d7d20da87f85ada
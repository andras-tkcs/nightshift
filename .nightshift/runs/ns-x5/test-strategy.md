# ns-x5 test strategy

Inputs: `acceptance.md` (AC-1..AC-8), `design.md`, `docs/ns-x5-plan.md` (D1-D11, Tests, manifest). Framework: bats (`tests/bats/`).

## Expected-failure marker (bats)

Bats has no xfail marker, and `skip` would hide the test. This run uses the same convention as `plan/ns-5` and `plan/ns-144`: a strict wrapper `ns_xfail`, defined locally in each touched test file (`helpers.bash` says it is never edited). Each acceptance case body is a function, and the `@test` calls it like this:

```bash
ns_xfail "ns:ns-x5 acceptance" x5_cache_hit
```

`ns_xfail` runs the function in a background subshell (`"$@" & wait "$!"`), so errexit stays on inside it. The case passes when the function fails. When the function succeeds, the case fails with `XPASS (ns:ns-x5 acceptance): ...` (strict).

## What is already on plan/ns-x5 (phases must not add these again)

Every new case's title ends with `(ns-x5)`. Duplicate titles break bats.

- `tests/bats/conductor-loop.bats`: 16 cases, the helpers `ns_xfail`, `x5_count`, `x5_wait_count`, `x5_sbx12`, `x5_sbx13` and `x5_pass_then_hit`, and one function per case. They cover the p1 brief's list 6a-6k. The p1 manifest check `grep -c '(ns-x5)" {' tests/bats/conductor-loop.bats` is already 16.
- `tests/bats/stack-pr.bats`: 4 cases, plus `ns_xfail` and `x5_main_ahead`. They cover the p2 brief's list 2a-2d. The p2 check `>= 4` is already met.

Deviations from the briefs. Each one makes a case fail on today's code for the right reason instead of passing without the implementation:

- 6c (lock leak): also asserts that `feature.checks.lock` exists after the call. Without that, `flock -n` on an absent file succeeds today.
- 6d (stale lock): also asserts that `feature.checks.json` was written, so the call went through the locked path of D3.
- 6f cache misses (new commit, `--force`, untracked file, modified file): before the change, each case first proves a cache hit (`x5_pass_then_hit`, count 1). The rerun is then caused by the change, not by a missing cache. The failure case also asserts that the json records `rc == 1`. The dirty-pass case makes a third call that must be a cache hit.
- 6i: the positive and negative wrong-target cases are one case. It makes a call with nothing pushed (no `warning:`), then pushes `fix/sbx-13` from a separate clone and calls again (warning).
- 6j: after `merge` (no `warning:`), an explicit `checks sbx-12 feature` must warn about the unmerged `origin/feature/12--p2-beta`. This shows the warning exists and that merge suppresses it.
- 6k: `--force` must succeed and `--bogus` must exit 2 with `[--force]` in the usage text.
- 2b: also asserts that `stack-base` dies with `no code worktree` after the code worktree is removed (D8). Without that, the up-to-date case passes today.

The brief's edits to existing stack-pr cases are not made here: pushing `develop` in "stack-base records the profile's base branch, not main" and the remote-SHA assertion in the one-open-PR case. p2 makes them, because they are fixture changes that only make sense together with D8.

## Removing the markers

- p1-checks-cache: implements D1-D7 and, in the same commit, deletes every `ns_xfail "ns:ns-x5 acceptance" ` prefix in `tests/bats/conductor-loop.bats`. It then deletes that file's `ns_xfail` helper and its comment. Inlining a function body into its `@test` is allowed if no assertion changes.
- p2-stack-base-flow: the same for `tests/bats/stack-pr.bats`.
- Check after p2: `grep -n 'ns_xfail' tests/bats/*.bats` prints nothing.

## Pyramid

- Unit (0): the behaviour is a shell CLI around git, flock and the ledger. No pure function is worth testing on its own.
- Integration (20): every case runs the real `bin/ns-conductor` against a temp config, a bare fake remote (`make_remote`), real git worktrees and real `flock`/`setsid`. They never touch `$NS_LEDGER` or the network. The checks cases count invocations through a check command that appends to `$BATS_TEST_TMPDIR/count`, outside the worktree, so the tree stays clean. Concurrency is synchronised by polling that file (up to 20 s), not by a fixed sleep. The only sleep is the 3 s inside the first call's check command, which keeps the lock held.
- End to end (0): `tests/e2e` runs against the sandbox and gains nothing over the bats cases here. AC-8's full-suite run through `ns-conductor checks ns-x5 feature` is the real-world exercise.

## AC to test mapping

| AC | Proof | Kind | Marker now |
|---|---|---|---|
| AC-1 lock | `conductor-loop.bats`: "a concurrent second call waits and reports the first call's PASS", "... reports the first call's FAIL and exit code" (count 1, equal exit codes, `another run of feature`, `result of the concurrent run on tree`), "a lock left by a killed process does not block a later call", "a process a check leaves running does not hold the checks lock" | test | xfail |
| AC-2 cache hit | "a second call on the same clean tree is a cache hit and writes rc 0" (count unchanged, `cached PASS for tree <HEAD^{tree}>`, `feature.checks.rc` = 0); "for a T1 run, checks fix is a cache hit of checks feature" (canonical target, `fix.checks.rc` = 0, no `fix.checks.log`) | test | xfail |
| AC-3 (a) tree changed | "a new commit reruns the checks" | test | xfail |
| AC-3 (b) target differs | No separate case. The key includes the canonical target (D6). Phase and feature targets use different worktrees and json files, so the existing per-phase checks cases already run each target. The T1 `fix`->`feature` case proves that only canonical equality hits | test (indirect) | xfail |
| AC-3 (c) earlier failure | "an earlier failure reruns the checks and is never reported as a pass" | test | xfail |
| AC-3 (d) `--force` | "--force reruns the checks after a pass"; "accepts --force as the third argument and rejects anything else with exit 2" | test | xfail |
| AC-3 (e) dirty worktree | "an untracked file in the worktree reruns the checks", "a modified tracked file reruns the checks", "a pass made while an untracked file was present is not cached" | test | xfail |
| AC-4 wrong target | "warns when the worktree lacks the run's pushed code branch, and not before"; "merge's internal checks print no warning; an explicit call does" (phase branch ref). The ns-x4 cause is a manifest `final_checks` item (`RUN/notes.md` / PR Follow-ups via `ns-conductor note`) | test + review | xfail |
| D1 (supports AC-4) | "a run retiered after fix-branch still checks its --fix worktree" | test | xfail |
| AC-5 skills | Commands: `grep -n 'bats' plugins/ns/agents/integrator.md` prints nothing; `grep -n 'only the tests covering the files you change' bin/ns-conductor plugins/ns/agents/implementer.md` prints a line per file; `grep -n 'ns-conductor checks' plugins/ns/skills/dod/SKILL.md`; reading the p2 diff of the run/implement skills | command + review | n/a |
| AC-6 stack-base timing | Code part (D8), `stack-pr.bats`: "stack-base with no open run PR merges origin/main when behind and pushes the code branch", "stack-base on an up-to-date code branch makes no merge and pushes nothing; it dies without a code worktree", "stack-base exits 6 on a conflict with origin/main and sets no integrate_from", "stack-base undoes its merge when the push is refused, and a retry pushes". Prose part: `grep -n '## Sync' plugins/ns/skills/run/SKILL.md` prints one line; `grep -n 'merges .origin/<base>. if behind' plugins/ns/skills/run/SKILL.md plugins/ns/agents/integrator.md` prints nothing; reading the diff | test + command + review | xfail (tests) |
| AC-7 docs | Commands: `grep -n 'checks.json' docs/conductor.md`, `grep -n -- '--force' docs/conductor.md`, `grep -n 'ns-x5' CHANGELOG.md` in `[Unreleased]`, `tests/docs-check` (and `--final` in p3) exits 0; a reviewer reads `### checks` for lock, cache key/store/invalidation, `--force` and the warning | command + review | n/a |
| AC-8 gates | Commands: `tests/lint` exits 0; `bats tests/bats/conductor-loop.bats tests/bats/conductor.bats` passes; the full `bats --jobs "$(nproc)" tests/bats` passes once through `ns-conductor checks ns-x5 feature` | command | n/a |

No AC lacks a test or a command. AC-5 and the prose part of AC-6 are about agent instructions, so a grep plus a diff review is the strongest proof available. A bats case on the worker prompt text would belong in `tests/bats/conductor.bats`, which is outside p2's touches, so the strategy leaves it to the manifest grep.

## Verification done

- With the markers in place, `bats -f 'ns-x5' tests/bats/conductor-loop.bats tests/bats/stack-pr.bats` reports all 20 cases `ok` (expected failure). None errors at collection. `tests/lint` exits 0.
- With the prefixes stripped (scratch copy, today's code, deleted afterwards), each case fails on the assertion about the missing behaviour:
  - lock cases: count 2 instead of 1.
  - leak case: no lock file.
  - stale case: no `feature.checks.json`.
  - cache-hit and miss cases: no `cached PASS` (or count 2 on the hit).
  - failure case: no json.
  - canonical `fix`: no `cached PASS`.
  - retier: `no worktree for feature` at `--feature`.
  - wrong target and merge: no `warning:`.
  - usage: `--force` gives exit 2.
  - stack-base: no merge of origin/main, or exit 0 where 6, a push failure or `no code worktree` is expected.
- The strict XPASS direction cannot be checked before the implementation exists. The phases' acceptance (`bats tests/bats/conductor-loop.bats` / `stack-pr.bats` exit 0 after the markers are removed) covers it.

## Fixtures

None new on disk. The cases reuse each file's `setup()`, `write_profile_to`/`set_test_cmd`, `commit_plan`, `mkphase`, `review_phase`, `pr_list`, `make_remote` and the gh stub. The counting command is `echo x >>$BATS_TEST_TMPDIR/count`, with an optional tail (`; sleep 3`, `; false`, the `setsid sleep 30` leaker, `; pwd >cwd`). A refused push uses a `pre-receive` hook (`exit 1`) in the bare remote, which the case removes again.

## Environment notes

- Inside a Nightshift session, run bats as `env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats ...`.
- Needs `flock` and `setsid` (util-linux; present on ns-main).
- The lock cases take about 3 s each (the held check). The leak case leaves a `setsid sleep 30` running only if it fails before its `kill`.

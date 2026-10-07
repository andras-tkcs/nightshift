# Acceptance: ns-x5

Goal: a run executes the full bats suite only through `ns-conductor checks`, at most once per (worktree tree, target), on the worktree that actually holds the change.

1. AC-1 Lock: two concurrent `ns-conductor checks <id> <target>` calls on the same worktree run the profile's check commands once. The second waits and then reports the first run's result and exit code. Proven by a bats test in `tests/bats/conductor-loop.bats` that uses a check command that counts its invocations (count == 1, both exit codes equal). A lock left by a dead process does not block a later call (bats test).
2. AC-2 Cache hit: after a passing `checks` on a tree, a second call with the same `git rev-parse HEAD^{tree}` and target runs no check command, prints a line naming the cached tree SHA, and exits 0 (bats: invocation count unchanged). It still writes `<target>.checks.rc`.
3. AC-3 Cache miss/never-green-by-cache: the checks run again when (a) the tree SHA changed, (b) the target differs, (c) the earlier run failed, (d) `--force` is given, or (e) the worktree has uncommitted or untracked non-ignored changes. One bats test per case (a), (c), (d), (e) at minimum. A failed result is never reported as a pass.
4. AC-4 Wrong target: when the checked target's HEAD does not contain the run's latest code commit (for example a T1 run whose change is on the `--fix` branch while `checks <id> feature` resolves elsewhere, or a phase branch ahead of the target), `checks` prints a warning on stderr naming both refs. Proven by a bats test. The cause found for ns-x4 is written in the PR body or `RUN/notes.md`.
5. AC-5 Skills: `plugins/ns/skills/implement/SKILL.md`, `plugins/ns/skills/run/SKILL.md`, `plugins/ns/agents/implementer.md`, `plugins/ns/agents/integrator.md` and the worker prompt in `bin/ns-conductor` (currently "run these checks and make them pass") tell workers to run only the test files they touch, and say the full suite runs only via `ns-conductor checks`. Check: `grep -n 'bats' plugins/ns/agents/integrator.md` shows no direct bats invocation instruction; reading the diff shows the new guidance.
6. AC-6 Stack-base timing: the run/implement skill docs place the "merge `origin/<base>` if behind" / `ns-conductor stack-base` step at the end of implement, before the review board, and the integrator no longer merges the base after checks have passed (unless stack-base or a conflict changed the tree). Checked by reading the diff of `plugins/ns/skills/run/SKILL.md`, `plugins/ns/skills/implement/SKILL.md` and `plugins/ns/agents/integrator.md`.
7. AC-7 Docs: `docs/conductor.md` `### checks` documents the lock, the cache (key, where it is stored, invalidation), `--force` and the warning; `CHANGELOG.md` `[Unreleased]` has an entry. `tests/docs-check` exits 0.
8. AC-8 Gates: `tests/lint` exits 0 and `bats tests/bats/conductor-loop.bats tests/bats/conductor.bats` passes; the full `bats --jobs "$(nproc)" tests/bats` passes once in `ns-conductor checks <id> feature`.

## Assumptions
- Item 5's "merge origin/main if behind (stack-base)" means both the run skill's integrate step "merges `origin/<base>` if behind" and the `stack-base` call. `stack-base` also sets `budget.integrate_from` (the integrator's budget margin); moving it earlier must not grant that margin before integrate starts. Planner decides: keep the margin tied to `step=integrate`, or split the merge out of `stack-base`.
- `merge` calls `loop_checks feature` internally. The cache and lock apply there too, so a merge commit (a new tree) always reruns.
- The cache key also covers the resolved profile checks (for example a hash of the commands), so changing the profile invalidates it. The exact store location is the planner's choice under `logs/<id>/`.

## Non-goals
- No change to which commands the profile's checks run, or to `ns stack merge` checks.
- No CI-side caching. No change to the pool lock or `budget.lock` semantics.

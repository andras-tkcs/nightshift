# Plan review: ns-x5

Reviewed: `docs/ns-x5-plan.md` against the plan and plan-manifest skills, `RUN/acceptance.md`, `RUN/design.md`, and the code as it is. I checked these references and they match: `bin/lib/conductor-loop.sh` (:23, :30, :106-:233, :203-:208, :236, :248-:267, :269, :282, :487), `bin/ns-conductor:116`/`:402`, `budget.py:50`, the stack-pr tests (:7, :68, :186), budget.bats (:244, :426-:470), the conductor-loop.bats tests at :151, :174, :398 and :798, and the duplicate logs rows in `docs/conductor.md` (:269 and :272). The manifest passes validation: the ids are unique, `depends_on` is known and has no cycle, p1 and p2 have disjoint `touches`, p3 depends on both and is the retirement phase, every phase has a brief and acceptance, complexity is S or M, `max_parallel` is 2, and there are no manual steps.

1. **blocking**: D4 and D7 have the check commands inherit the lock fd. Any process a check starts that outlives the run will hold `<canon>.checks.lock` for its whole life: a daemon, a detached worker, a tmux server, a gradle or bazel server, or a stub worker that this repo's own bats suite starts under `setsid` (`bin/ns-conductor:267-279`). Every later `checks` call then waits 3600 s and fails with `checks busy`. The repo already learned this lesson: `bin/lib/pool.sh:51` says "A process started under the lock must close fd 9, or it holds the lock for its life", and `runs.sh:135` and `ns-conductor:267` close fd 9 for this reason. Those calls close only fd 9, not the new dynamic `{lfd}`. D4's claim that "a lock held by a dead process is released by the kernel" is only true when no descendant still holds the fd. Fix: settle it in the Design.
   - Either run `ns_profile_checks_run ... {lfd}>&-`, so the checks do not inherit the lock, and accept the orphan case. The ns-x4 overlap came from direct `bats` calls, which the skill changes address.
   - Or keep inheritance, but make the busy and timeout messages name the PIDs that hold the lock (for example from `/proc/*/fd`), document the daemon hazard in `docs/conductor.md`, and add a bats test whose check command starts `setsid sleep 30 &`, so the behaviour is pinned down.

2. **blocking**: D4's replay can report a tree that was never tested clean as PASS. Replay checks the waiter's `clean=1`, `tree`/`target`/`checks_sha` and `finished_epoch`. It does not check whether the first run was clean or whether its tree changed. Scenario: the first run starts with uncommitted edits (an implementer working in the `--fix` worktree), so the stored `tree` is `HEAD^{tree}` without those edits. The edits are discarded while the second call waits. The waiter is now clean on the same tree and replays a PASS that `HEAD` alone never earned. If `tree` is recorded after the run, the same happens when a commit lands mid-run. Fix: replay a PASS only when the stored `cacheable == true` (a FAIL may replay unconditionally), and say in D6 that the stored `tree` is the `tree` of the key taken before the run.

3. **blocking**: D8 pushes in the wrong order relative to recovery. When the push after a merge fails, the merge commit stays in the code worktree. On the next `stack-base` (the integrator's step 0, or a resumed Sync), `merge-base --is-ancestor origin/<branch> HEAD` succeeds, so `loop_stack_merge` returns 0 without pushing. `integrate_from` is then set and the base is printed. The checks then pass on a local tree that is not on `origin/<code branch>`, and the reviewers and the PR see a different head. Fix, either of:
   - On a failed push, undo the merge before `ns_die` (`git -C "$dir" reset -q --hard <pre-merge sha>`).
   - On the "nothing to merge" path, push when `HEAD` is ahead of `origin/$own`.

   Extend test 8(d): remove the hook, rerun `stack-base`, and assert that the remote has the merge.

4. **blocking**: D10 says `/ns:dod` runs `ns-conductor checks "$NS_RUN_ID" feature` "once in the foreground". The suite takes about 15 minutes, which is longer than the Bash tool's 600 s maximum. This contradicts `/ns:run` Start step 4: run it in the foreground only when the Bash timeout bounds it, otherwise background it and wait for `logs/<id>/<target>.checks.rc`. A cache miss (stack-base merged something, or a board fix landed) would kill the call half-way. Under D4 the orphaned bats would also keep the lock. Fix: in D10 and p2 step 6, have dod start the call in the background, wait for `logs/<id>/feature.checks.rc`, and take the rows from the call's output.

5. **blocking**: D10 builds dod's rows only from `PASS|FAIL|SKIP` lines, so the D5 warnings (`warning: <dir> HEAD (...) does not contain <ref> ...`) are dropped. A cached or fresh PASS on a code worktree that lacks the run's pushed code, or an unmerged phase branch, would then go into `RUN/dod.md` and the PR as green: a stale tree reported as green, which is the ns-x4 failure. Fix: in D10 and p2 step 6, every `warning:` line that `ns-conductor checks` prints becomes a FAIL row ("checked tree lacks <ref>"). In `integrator.md`, make that row a stop condition.

6. **non-blocking**: p1 is at the top of M and carries the concurrency-sensitive part (lock, replay, cache, fd semantics), plus an unrelated stack-base change, in one Sonnet phase. Splitting D8 into its own phase is better. It must depend on p1 because both share `bin/lib/conductor-loop.sh`, and it could also take `tests/bats/stack-pr.bats` and `tests/bats/budget.bats`. If p1 stays as one phase, consider `model: opus` with a `model_reason`.

7. **non-blocking**: The plan says "All decisions of RUN/design.md are taken as made", but D10 differs from the design in two places:
   - T0 Sync runs between steps 2 and 3. The design says after step 3.
   - The integrator never calls `checks`, and dod does it instead. The design says the integrator calls it when HEAD changed.

   Both changes are reasonable, so state them as deliberate changes. Otherwise the board's acceptance reviewer may flag them.

8. **non-blocking**: p2 step 3f replaces only "It then merges `origin/<base>` if behind," in `/ns:run` Integrate step 2. That step's exit-6 clause "it resolves the conflicts and reruns the checks" stays, which contradicts the new `integrator.md` (commit and push, with no checks call). The same goes for the integrator stop condition "or the checks are red after resolving them". Fix: spell out the replacement text for both: the checks come from `/ns:dod`.

9. **non-blocking**: In p1 test 7h ("push one more commit to origin/fix/sbx-13 from a separate clone"), `origin/fix/sbx-13` does not exist after `fix-branch`, which never pushes (`conductor-loop.bats:115`). Spell out the steps: `git -C "$c" checkout -q -b fix/sbx-13 origin/main`, commit, push.

10. **non-blocking**: AC-3(e) says "uncommitted or untracked". Test 7e covers only untracked files. Add a case with a modified tracked file (dirty, so it reruns).

11. **non-blocking**: The ns-x4 cause note (AC-4) depends on the conductor reading the Risks section ("records it ... before integrate"). No skill step or phase does it, and `final_checks` only catches its absence at the end. Name the moment explicitly, for example "the conductor, right after Sync".

12. **non-blocking**: The worker prompt's closing line at `bin/ns-conductor:414` ("then the checks you ran with their results") is not aligned with D9, which renames the matching phrase in `implementer.md` to "the tests you ran". Add it to p2 step 1.

13. **non-blocking**: p3's CHANGELOG bullet says `logs/<id>/<target>.checks.json`, while D6 names the file `<canon>.checks.json`. Use `<canon>` or "the canonical target".

14. **non-blocking**: Two test and robustness notes:
   - In tests 7a and 7c, the background processes should close bats' fd 3 (`3>&-`), so a leaked child cannot hang bats.
   - `conductor_merge` merges in the feature worktree before `loop_checks` takes the lock, so it can change the tree under a running explicit `checks`. D6's "tree unchanged ⇒ cacheable" rule keeps the cache safe. Mention this in `docs/conductor.md`, or take the lock before the merge.

REVIEW verdict=changes

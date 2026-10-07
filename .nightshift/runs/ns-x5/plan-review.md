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

## Round 2

All 14 first-round findings are fixed or addressed; finding 6 is fixed but moved the size problem to p2 (item 15). I found 7 new problems, all non-blocking: one is a Sizing for Sonnet issue, the others are small gaps in briefs.

I checked these against the code and they match: the cited lines in `bin/lib/conductor-loop.sh`, `bin/ns-conductor:402` and `:414`, the step numbers in the run skill (T0 :41–44, T1 :50–56, Integrate :97) and the integrator, the dod skill's sections 1.3 and 2, and the docs lines (`docs/conductor.md` :102, the stack-base and checks sections, the duplicate logs row; `docs/usage.md` :107 and :344). The test fixtures the briefs use exist: `$FWT`, `$BARE`, `$REMOTE`, `$CODE_WT`, `set_test_cmd`, `<bare>/hooks/pre-receive` (also used in `tag.bats:228`), and the sbx-13 ledger path.

The manifest is valid:
- The phase ids are unique and the dependencies form a chain p1 → p2 → p3 with no cycle.
- The phases run one after another, so they can share `touches`; p3 is the retirement phase.
- Every phase has complexity S or M, a brief and acceptance items; `max_parallel` is 2 and there are no manual steps.
- p1 needs at least 16 tests named `(ns-x5)` and the brief defines 17; p2 needs 4 and defines 4.

Every acceptance criterion AC-1 to AC-8 maps to a phase step or a `final_checks` line.

I could not run a quick bash test of `{lfd}>&-` on a function call (the sandbox denied the command). Test 6a would catch it if the lock were dropped before the record step: the waiter would run the checks too and the count would be 2.

### First-round findings

1. **Fixed** (was blocking, lock fd inherited by checks). D4 and D7 now close the lock fd for the checks with `{lfd}>&-`, D11 explains why, and test 6c pins it down with a `setsid sleep` that must not hold the lock.
2. **Fixed** (was blocking, replaying an untested PASS). Replay now needs `cacheable == true` for a PASS, and D3 step 6 and D6 say the key is taken before the run.
3. **Fixed** (was blocking, push order). D8 resets to the commit before the merge when the push fails. Test 2d reruns `stack-base` after removing the hook and checks that the remote has the merge.
4. **Fixed** (was blocking, dod running the suite in the foreground). D10 now runs the call in the background and waits for the `.rc` marker file; p2 step 9 repeats it.
5. **Fixed** (was blocking, warnings dropped from dod). Each `warning:` line becomes a FAIL row `checked tree is stale`, and that row is an integrator stop condition (D10, p2 step 8).
6. **Fixed, with a side effect** (was non-blocking, p1 too big). p1 now holds only the checks work. But p2 grew; see item 15.
7. **Fixed.** D11 lists the deliberate changes from the design.
8. **Fixed.** D10 and p2 steps 6f and 8 give the replacement text for the exit-6 clause and the stop condition.
9. **Fixed.** Test 6i spells out how the branch is created and pushed.
10. **Fixed.** Test 6f adds the modified tracked file case.
11. **Fixed.** Risks names the moment: `ns-conductor note` right after `ns-conductor feature`, and `final_checks` repeats it.
12. **Fixed.** p2 step 4 replaces the closing line at `bin/ns-conductor:414`.
13. **Fixed.** The CHANGELOG bullet now says `<canonical target>`.
14. **Fixed.** Background processes in the tests use `3>&-`, and the merge race is in Risks and in p1 step 7.

### New findings

15. **non-blocking** (Sizing for Sonnet): p2 now touches 10 non-test files: `conductor-loop.sh`, `ns-conductor`, 5 skill and agent files and 3 docs. That is above the M limit of "about 8 source files". It also mixes a code change with prose edits in nine files. A T2 plan cannot add a fourth phase. Fix: move p2 steps 10–12 (`docs/conductor.md` stack-base and worker prompt, `docs/usage.md`, `docs/agents.md`) into p3. p3 already touches `docs/conductor.md` and `docs/usage.md`, and reconciles those docs anyway. That leaves p2 with 7 non-test files.

16. **non-blocking** (p1 step 6, tests a–f, j and k): the `setup()` of `conductor-loop.bats` creates sbx-12 as a T2 run with no feature worktree. Every new `checks sbx-12 feature` test would die with `no worktree for feature`. Fix: say that each of these tests starts with `commit_plan; ns-conductor feature sbx-12 >/dev/null`, as the existing checks tests at :163–:262 do. Test 6e already refers to `$FWT`.

17. **non-blocking** (D4 against D7): D4 says "pass the fd number in as an argument, see D7". D7's signature `loop_checks_body <canon> <dir> <key> <clean>` has no fd argument and reads `$lfd` from the caller's scope. That leaves a small decision open. Fix: pick one, for example add `<lfd>` as a fifth argument and use `{lfd}>&-` on a local variable.

18. **non-blocking** (p2 step 2a): "commit a new file through `other_run_branch`-style clone on main and push" does not work if the helper is copied as is. `other_run_branch` runs `checkout -b <branch> origin/<base>`, and `checkout -b main` fails because a clone already has `main`. Fix: spell it out: `w=$(mktemp -d "$BATS_TEST_TMPDIR/m.XXXXXX"); git clone -q "$REMOTE" "$w"; printf x >"$w/new.txt"; git -C "$w" add new.txt; git -C "$w" commit -q -m new; git -C "$w" push -q origin main`.

19. **non-blocking** (p2 step 6b and 6c): inserting a Sync step shifts the step numbers in T0 and T1. T1 step 6 ("repeat from step 5") and the brief's own "step 5", "step 6" become wrong. Fix: tell the worker to renumber and to update the cross-references, so "repeat from step 5" points to the code-reviewer step.

20. **non-blocking** (p2 steps 10–12, leftover wording): three existing sentences still say the integrator "reruns the checks" itself:
    - `docs/conductor.md` stack-base: "After resolving, the caller commits and reruns `checks <id> feature`."
    - `docs/usage.md` stacking paragraph: "resolved by the integrator, which reruns the checks".
    - `docs/agents.md` integrator entry: "it resolves and rechecks".

    The brief also asks for the worker-prompt closing line in `docs/conductor.md`'s prompt block, but that block has no closing line today. Fix: name these three sentences, with the new wording "the checks then run in `/ns:dod`", and say "add" for the closing line.

21. **non-blocking** (D5 with D10): the warning lists every phase not in state `merged` whose branch exists on origin. A board fix round that is left unmerged on purpose (its findings go into the PR as open items) will make `/ns:dod` report `checked tree is stale`. The integrator then stops at gate 1.5. That is safe, but it is a false alarm. Fix: limit the phase refs in D5 to `running`, `review` and `done` phases, or name the open-items case in Risks so the gate 1.5 question says why it stopped.

REVIEW verdict=approve

## Planner's resolution

- Round 1, all 14 findings: applied (D4/D7 close the lock fd for the checks, D4 replays a PASS only when cacheable, D8 undoes the merge on a failed push, D10 /ns:dod waits on the marker file and turns `warning:` lines into FAIL rows, D11 lists the refinements of design.md, p1 split so it holds only the checks work, test and wording fixes).
- Round 2: 15 (p2 size) applied: the reference-doc edits moved to p3, p2 has 7 non-test files. 16, 17, 18, 19, 20 applied as suggested. 21 applied by excluding board fix rounds `fix-<n>` from the phase refs of the warning (an unmerged board fix is an open item, not missing code).

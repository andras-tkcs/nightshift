# Board code review: ns-x5

Range: `git diff origin/main...origin/feature/x5`, head 852727e9423c0792fbd02c1d12d847500065776e. Plan: `origin/plan/ns-x5:docs/ns-x5-plan.md` (D1 to D11, manifest p1 to p3), `RUN/acceptance.md` AC-1 to AC-8. I read the diff, the plan, the acceptance criteria and RUN/notes.md. I did not run bats, as the caller asked. The caller reports that the full suite ran through ns-conductor and that only the accepted known failures bootstrap.bats #32 and kill.bats #464 failed. I was not given any worker log.

## Findings

- non-blocking · bin/lib/conductor-loop.sh:387 · `key=$(loop_checks_key ...)`: the `ns_die` in `loop_checks_key` exits only the command substitution. When `rev-parse HEAD^{tree}` fails, `key` is empty and the checks still run. `jq --argjson k ""` then fails, so nothing is recorded. This is safe because it never gives a false pass, but the die message does not stop the call. · Use `key=$(loop_checks_key "$dir" "$canon") || exit`.
- non-blocking · bin/lib/conductor-loop.sh:161 · The rewritten `conductor_stack_base` comment line is about 160 characters, much longer than the lines around it. · Wrap it like the rest of the comment.
- non-blocking · plugins/ns/skills/run/SKILL.md:44 · T0 step 4 reads "`ns-conductor checks <id> feature`; the checks of Sync are its first run". A reader can take this to mean the checks run again right after Sync. · Reword it: "The Sync checks are this step's first run; on failure launch `ns:implementer` ... and rerun `ns-conductor checks <id> feature` ...".
- non-blocking · docs/agents.md:85 · The integrator Stacking sentence reads "it resolves, commits and pushes; the checks run in `/ns:dod`, or escalates at gate 1.5". The semicolon splits the either/or, so the "or" has no clear subject. · Write "it resolves, commits and pushes (the checks then run in `/ns:dod`), or escalates ...", as run/SKILL.md Integrate step 2 already does.
- non-blocking · docs/conductor.md:145 · "`ns stack merge` runs the checks" became "The stack merge command of `ns` runs the checks". The new wording is vaguer and the plan does not ask for it. · Restore the command name in backticks, unless docs-check needs this form; if so, note why.
- non-blocking · CHANGELOG.md:18 · `### Changed` sits after `### Fixed`. That is what the plan asks for, but it is against Keep a Changelog order (Added, Changed, ..., Fixed, Security). · Optionally move it above `### Fixed`.

## What I checked

- Correctness of `loop_checks`, compared with D3/D4/D6/D7:
  - The order is canon, budget guard, worktree check, warning, lock, clean flag and key, replay or cache, then run.
  - Every path, including the 3600 s lock timeout (exit 1), stays inside the subshell, so the rc marker is always written under the caller's target name.
  - `{lfd}>&-` on the `ns_profile_checks_run` call keeps the lock away from leftover processes.
  - Replay needs a wait, a clean tree, the same key, `finished_epoch >= start`, and a FAIL or a cacheable PASS.
  - A cache hit needs `rc == 0`, `cacheable == true` and a clean tree.
  - The record is written with temp file + `mv`, after `rm -f` at the start of the run, and is cacheable only when the tree was clean before and after and the tree did not change.
  - The usage check accepts only `--force` as the third argument.
  - `conductor_merge` keeps the call without flags.
- `loop_code_wt` now follows `feature_branch`, with the tier as fallback (D1). `loop_checks_canon` maps only `fix`, and only when it is the same worktree.
- `loop_checks_warn` follows D5: it skips `fix-<n>` rounds, skips refs that are missing, and always returns 0.
- `loop_stack_merge` follows D8:
  - It fetches first and returns early when nothing is behind, so nothing is pushed.
  - It checks for dirty and clashing files, then merges with `--no-ff`.
  - On a conflict it records `stacked_on`, checkpoints and exits 6.
  - When the push is refused it runs `reset --hard "$pre"` and dies.
  - `integrate_from` is set only after it succeeds. The no-top path now also needs the code worktree.
- Tests: the 16 conductor-loop and 4 stack-pr acceptance tests were committed first (855863f) with a strict xfail wrapper, which the implementation commits remove.
  - 14c5db4 only lengthens the lock tests' `sleep 3` to `sleep 10`. That makes the overlap more reliable; it does not weaken the tests.
  - 027f77c adds fixture setup (`develop` pushed, run state `running`) and a stronger remote-ref assertion.
  - No test was deleted or skipped.
- Acceptance:
  - AC-1 to AC-4: bats tests for lock, stale lock, no lock leak, cache hit, misses (a), (c), (d) and (e), and the warning. The ns-x4 cause is RUN/notes.md note 2.
  - AC-5: the worker prompt in `bin/ns-conductor`, `implementer.md`, `integrator.md` (no "bats"), run/implement skills.
  - AC-6: Sync before review in run/implement; the integrator's base merge step is removed.
  - AC-7: `docs/conductor.md` `### checks` covers the lock, the cache, `--force` and the warnings; CHANGELOG has the entry.
  - AC-8: as the caller reports.
- Docs: conductor.md (checks, stack-base, budget margin, worker prompt, logs table with the duplicate row removed), usage.md, agents.md, the dod skill. They match the code.
- Hygiene: there are no `.nightshift/` files in the diff and `docs/ns-x5-plan.md` is deleted. Every file is in its phase's `touches`. No secrets. No text copied from untrusted sources (R-SEC-3).

## Summary

The diff does what the plan's D1 to D11 ask for. AC-1 to AC-8 are met and covered by tests or by reading the diff. The tests were written first and none was weakened. There are no blocking findings. The six non-blocking items are wording or robustness polish for the PR body or a follow-up.

REVIEW verdict=approve head=852727e9423c0792fbd02c1d12d847500065776e

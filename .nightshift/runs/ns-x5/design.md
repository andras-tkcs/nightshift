# Design: ns-x5 (T2)

## Modules touched
- `bin/lib/conductor-loop.sh`: `loop_checks`, `loop_checks_body`, `conductor_checks`, `loop_code_wt`, `conductor_stack_base`, usage line. New helpers `loop_checks_target` (canonical target), `loop_checks_key`, `loop_checks_warn` (AC-1..4).
- `bin/ns-conductor`: worker prompt rule 4 (line ~402) (AC-5).
- `plugins/ns/skills/run/SKILL.md`, `plugins/ns/skills/implement/SKILL.md`, `plugins/ns/agents/implementer.md`, `plugins/ns/agents/integrator.md`, `plugins/ns/skills/dod/SKILL.md` (AC-5, AC-6; dod: see Risks).
- `docs/conductor.md` (`### checks`, `### stack-base`, logs table at lines ~269/272), `CHANGELOG.md` (AC-7).
- `tests/bats/conductor-loop.bats` (new tests), stack-base tests wherever they live today (AC-1..4, AC-6).
- Not touched: `plugins/ns/hooks/**` (risk zone), `bin/lib/config.sh`, `bin/ns-launch`, `bin/lib/profile.sh` (`ns_profile_checks_run` is reused unchanged).

## Interfaces
- `ns-conductor checks <id> <phase|feature> [--force]`. Exit codes unchanged (0 pass, 1 fail, 4 budget). `--force` skips the cache lookup (still takes the lock, still records the result).
- Canonical target: for T0/T1 the phase id `fix` names the same worktree as `feature` (`loop_phase_wt fix` = `<id>--fix` = `loop_code_wt`), so `fix` maps to `feature` for lock, cache, log and the integrator budget margin. `<target>.checks.rc` is still written under the name the caller gave (AC-2; the skills wait for that marker).
- Order in `loop_checks`: budget guard (as today) -> lock -> cache lookup -> run -> record -> rc marker. All inside the existing subshell, so every path writes the marker.
- Lock (AC-1): `flock` on `$logdir/<canon>.checks.lock`, one per run worktree. Try `flock -n`; when busy print `checks: another run of <canon> in <dir> is in progress; waiting` to stderr, then `flock -w 3600` (timeout: exit 1 `checks busy`, never a pass). The fd is inherited by the check commands on purpose: the lock lives until the last process running checks in that worktree exits, so an orphaned bats from a killed caller still blocks a second copy.
- Stale locks: flock locks are released by the kernel when the holder dies, so a leftover lock file never blocks; no PID files, no age heuristics. Bats: lock file left by a `kill -9`ed holder, next call runs.
- Waiter replay: after acquiring, if `<canon>.checks.json` has the same key and `finished` >= this call's start time, print `checks: result of the concurrent run on tree <sha>: PASS|FAIL`, the tail of the log on FAIL, and return its `rc` (pass or fail). Not applied to a dirty worktree (the waiter runs itself).
- Cache (AC-2/3): key = `tree` (`git -C <dir> rev-parse HEAD^{tree}`), canonical `target`, `checks_sha` (sha256 of `jq -cS '.checks // []'` of the resolved profile). Hit only when: not `--force`, worktree clean (`git status --porcelain` empty, i.e. no staged, unstaged or untracked non-ignored files), stored key equal, stored `rc == 0`. Hit prints `checks: cached PASS for tree <sha> (<canon>, <finished>); --force reruns`, runs nothing, leaves `<canon>.checks.log` intact (ns report keeps its rows), writes rc 0.
- Record: after a run, write the JSON via tmp+mv. A pass is stored as cacheable only if the tree was clean before the run and `HEAD^{tree}` and cleanliness are unchanged after it; otherwise stored with `cacheable: false`. A failure is always stored (for replay) but never hits.
- Wrong-target warning (AC-4), stderr only, explicit `checks` calls only (not merge's internal call): `git fetch -q origin` (on failure: one-line note, no warning); for `feature`, warn `warning: <dir> HEAD (<branch> <sha>) does not contain <ref> <sha>` for `origin/<ledger feature_branch>` and for every phase branch on origin whose phase is not `merged`; also warn when the worktree's branch differs from the ledger's `feature_branch`. For a phase target, compare with `origin/<phase branch>`.
- `loop_code_wt`: choose the worktree from the ledger's `feature_branch` (fix pattern -> `<id>--fix`, else `<id>--feature`), fall back to the tier when unset. Removes the dependence on `.tier`, which can change after `fix-branch` (gate 1.5 retier).
- `stack-base` (AC-6): after the stack-top merge (or with none), also merge `origin/<printed branch>` into the code branch when HEAD is behind it (`--no-ff`, same exit 6 on conflict), and push the code branch when it made a merge. Sets `budget.integrate_from` as today.
- Worker prompt rule 4 / implementer step 4: "Run lint and only the tests covering the files you change (for example `bats tests/bats/<file>.bats`). Do not run the full suite: it runs through `ns-conductor checks` after you finish." The check list stays printed for reference.

## Data
- New per run in `~/.config/ns/logs/<id>/`: `<canon>.checks.lock` (empty) and `<canon>.checks.json` `{tree, target, checks_sha, rc, cacheable, head, finished}`. Names avoid the `*.checks.log`/`*.checks.rc` globs of `bin/lib/runs.sh` and `bin/lib/report_logs.py`. No ledger schema change; no migration (absent file = miss).

## Skill flow (AC-5, AC-6)
- New "Sync" step at the end of implement, before review: T0 after step 3, T1 after implementer step B (before code-reviewer), T2/T3 when all phases are merged (before the board). The orchestrator runs `ns-conductor stack-base <id>`; exit 6: `git -C <code wt> merge --abort`, note it, go on (the integrator resolves it as today); exit 7: gate 1.5; exit 4: stop. Then `ns-conductor checks <id> feature`.
- Board/code-reviewer diff base becomes the branch stack-base printed (`origin/<pr-base>...origin/<feature>`), so a stacked run's reviewers do not review another run's code.
- Integrator: still runs `stack-base` first (idempotent: refreshes `integrate_from`, catches a newly opened stack top), drops its step 1 base merge, and calls `ns-conductor checks <id> feature` only when stack-base or a conflict changed HEAD; never `bats` directly, never `checks <id> fix`.
- `budget.integrate_from`: the margin stays tied to `step=integrate`. Both guards already require it (`bin/ns-conductor` `budget_guard_locked` line ~116, `plugins/ns/hooks/lib/budget.py` line 50), so setting it during implement gives no margin before integrate. If the run leaves `running` in between, the ledger clears it and the integrator's own `stack-base` call sets it again. No code change for this.

## ns-x4 cause (verified from `~/.config/ns/logs/ns-x4/conductor.jsonl` and its ledger)
- Tier was T1 (owner), so `checks ns-x4 feature` resolved through `loop_code_wt` to `nightshift-ns-x4--fix`: it ran on the right worktree. The "feature" label misled. Real problems: (1) it ran at 08:08, before the round-1 review fix commits (review 08:27/08:31), and was not rerun; (2) the integrator then ran `checks ns-x4 fix` (same worktree, separate log/rc, no integrator budget margin because only `feature` passes `who=integrator`); (3) implementers and the integrator ran `bats --jobs 8 tests/bats` directly 6+ times, overlapping (background jobs plus `pgrep` waits), and `/ns:dod` ran it again. Canonical `fix`->`feature`, the cache, the lock and the skill changes address each. Write this into `RUN/notes.md` or the PR body.

## Risks
- `/ns:dod` (run by the integrator) runs every profile check itself: a hidden extra full suite. Proposed: inside a run, dod takes the profile-check rows from `ns-conductor checks <id> feature` (cache hit) and runs only `commands.typecheck`/`audit`/extra DoD commands. Outside AC-5's file list; planner keeps or drops it.
- A check that leaves untracked non-ignored files makes the tree dirty, so the cache never hits there (safe, just slow). Document it.
- `stack-base` now pushes and merges the base: existing stack-base bats tests need updating; a push failure must die before `integrate_from` is set.
- Waiters hold the Bash tool for up to the suite length; the existing marker-file waiting rule still applies.

## Rejected alternatives
- PID/mtime lock files: needs stale detection, races; flock is already used (`budget.lock`).
- Cache keyed by HEAD commit: a merge or rebase with the same tree would miss; tree SHA plus clean check is exact.
- Cache inside the worktree or ledger: changes `git status`/the tree or bloats the ledger.
- Splitting the base merge into a new subcommand: more surface than extending `stack-base`, which already owns the merge into the code branch.
- Moving `integrate_from` to a new field set at `step=integrate`: the step check already gives that.

## Open questions (owner)
- None blocking. `--force` is new CLI surface but additive.

# ns-x5: run the full test suite once per tree, through `ns-conductor checks`

## Goal

A run should execute the project's full check suite (here: `bats`, about 15 minutes and 835 tests) only through `ns-conductor checks`, at most once per (worktree tree, target), and on the worktree that holds the change. Run ns-x4, a T1 rename, took 1h49m because the suite ran 5 to 6 times, sometimes two copies at once in one worktree. After this change: workers run only the tests that cover their files; `ns-conductor checks` takes a per-worktree lock, caches a pass by tree SHA, can be forced with `--force`, and warns when the checked worktree lacks the run's latest pushed code; the merge of the base branch moves to the end of implement, before review, so integrate does not invalidate checks that already passed. Request: ledger `request.text` of ns-x5 (no issue). Acceptance criteria: `RUN/acceptance.md` (AC-1 to AC-8). Design: `RUN/design.md`.

## Current state

- `bin/lib/conductor-loop.sh` (643 lines) holds the loop subcommands.
  - `loop_code_wt` (`:30`) picks `<id>--fix` for T0/T1 and `<id>--feature` otherwise from the ledger's `.tier` (`loop_tier`, `:23`). The tier can change after `fix-branch` (gate 1.5 retier), so the choice can drift from the branch that holds the code.
  - `conductor_stack_base` (`:106`-`:233`) merges the top open run PR into the code branch and sets `budget.integrate_from`; with no open run PR (`:203`-`:208`) it only prints the base branch. It never merges `origin/<base>` and never pushes.
  - `loop_phase_wt` (`:236`) maps `feature` to `loop_code_wt`, any other target to `<id>--<target>`. For T0/T1 `fix` and `feature` therefore name the same worktree but get separate logs and rc markers, and only `feature` gets the integrator's budget margin (`who=integrator`, `:258`).
  - `loop_checks` (`:248`-`:267`) runs, inside a subshell, the budget guard (only with `--budget`) and `loop_checks_body` (`:269`), which calls `ns_profile_checks_run` (`bin/lib/profile.sh:33`) into `logs/<id>/<target>.checks.log` and prints the tail on failure. It always writes `logs/<id>/<target>.checks.rc` last (tmp + mv). No lock, no cache.
  - `conductor_checks` (`:282`) accepts exactly `<id> <phase|feature>` and calls `loop_checks "$2" --budget`. `conductor_merge` (`:487`) calls `loop_checks feature` (no `--budget`) after the merge commit.
- `bin/ns-conductor:402` worker prompt rule 4: "Before finishing, run these checks and make them pass:" plus the profile's checks. `docs/conductor.md:248` documents it.
- `budget_guard_locked` (`bin/ns-conductor:116`) gives the integrator margin only when `step == "integrate"` and `budget.integrate_from` is set; `plugins/ns/hooks/lib/budget.py:50` checks the same. Setting `integrate_from` earlier gives no margin before integrate.
- Skills: `plugins/ns/skills/run/SKILL.md` (T0 `:41`-`:44`, T1 `:50`-`:56`, T2 `:69`-`:70`, Review board `:85`, Integrate `:97`), `plugins/ns/skills/implement/SKILL.md` (section 5 `:55`), `plugins/ns/agents/implementer.md` (step 4 `:29`), `plugins/ns/agents/integrator.md` (step 0 `:26`, step 1 base merge `:27`, step 2 `/ns:dod` `:28`), `plugins/ns/skills/dod/SKILL.md` (runs every profile check itself, `:19`, `:23`).
- Tests: checks tests in `tests/bats/conductor-loop.bats:151`-`:262` and `:798`; stack-base tests in `tests/bats/stack-pr.bats:68`-`:440` (setup `:7` runs `ns-conductor fix-branch sbx-12`, so a code worktree always exists) and `tests/bats/budget.bats:244`, `:426`-`:470`. The test helper fixes `NS_NOW=2026-10-02T21:00:00Z` (`tests/bats/helpers.bash:15`), so anything compared in time must use the real clock (`date +%s`), not `ns_now`.
- Docs: `docs/conductor.md` `### checks` (`:139`), `### stack-base` (`:127`), budget-check margin (`:102`), worker prompt (`:234`), logs table (`:259`-`:272`, which lists `<target>.checks.log`, `<target>.checks.rc` twice); `docs/usage.md:107` (stacking), `:344` (`/ns:dod`); `docs/agents.md:84` (integrator).
- ns-x4 cause (verified by the architect from `~/.config/ns/logs/ns-x4/conductor.jsonl` and its ledger): tier was T1, so `checks ns-x4 feature` already resolved to `nightshift-ns-x4--fix`, the right worktree; the "feature" label misled. The real problems: (1) it ran at 08:08, before the round-1 review fix commits (08:27/08:31), and was not rerun; (2) the integrator then ran `checks ns-x4 fix` (same worktree, separate log and rc, no integrator margin); (3) implementers and the integrator ran `bats --jobs 8 tests/bats` directly 6+ times, overlapping, and `/ns:dod` ran it again.

## Design

All decisions of `RUN/design.md` are taken as made, except the deliberate refinements listed in D11 (each fixes a bug the plan review found or saves a suite run). The subsections below are the spec the phases implement; briefs point here by subsection name.

### D1. Canonical target and the code worktree

- `loop_code_wt` chooses from the ledger's `feature_branch`: when it equals `ns_branch_name "$(jq -r '.git.fix_branch' <<<"$profile")" "$id"` the worktree is `ns_run_worktree_path "$profile" "$id--fix"`; when it is set to anything else, `ns_run_worktree_path "$profile" "$id--feature"`; when unset, the current tier rule (T0/T1 `--fix`, else `--feature`). Update its comment.
- New `loop_checks_canon <target>`: prints `feature` when `<target>` is exactly `fix` and `ns_run_worktree_path "$profile" "$id--fix"` equals `$(loop_code_wt)`; otherwise prints `<target>` unchanged. (`fix-<n>` board rounds are phases and never map.)
- The canonical name `<canon>` is used for the worktree (`loop_phase_wt "$canon"`), the lock, the cache file, the log (`$logdir/<canon>.checks.log`) and the budget margin (`who=integrator` when `<canon>` is `feature`). The rc marker stays `$logdir/<target>.checks.rc` under the name the caller gave.

### D2. `ns-conductor checks` interface

- Usage: `ns-conductor checks <id> <phase|feature> [--force]`; the same text in `conductor_loop_usage` and in `conductor_checks`'s `ns_usage`. Two args, or three with the third exactly `--force`; anything else is the usage error (exit 2 as today).
- Exit codes unchanged: 0 pass, 1 fail (also lock timeout), 4 budget.
- `loop_checks <target> [--budget] [--force]`, flags in any order. `--budget` marks an explicit `checks` call: it runs the budget guard and the wrong-target warning (D5). `conductor_merge` keeps calling `loop_checks feature` with no flag: lock and cache apply, no budget guard, no warning.

### D3. Order inside `loop_checks`

Everything after the `rm -f "$rcf"` stays inside the existing subshell, so every path writes the rc marker:

1. `canon=$(loop_checks_canon "$target")`.
2. With `--budget`: `budget_guard checks "$who" || exit` (`who=integrator` when `canon` is `feature`).
3. `dir=$(loop_phase_wt "$canon")`; `[ -d "$dir" ] || ns_die "no worktree for $target at $dir"` (message unchanged; a test greps `no worktree for feature`).
4. With `--budget`: `loop_checks_warn "$canon" "$dir"` (D5).
5. Lock (D4).
6. `clean`: 1 when `loop_wt_clean "$dir"` succeeds. `key=$(loop_checks_key "$dir" "$canon")`. This key, taken before the run, is the one recorded (D6).
7. Replay (D4), then cache lookup (D6).
8. Otherwise run (D7) and record (D6); exit with the run's rc.

### D4. Lock and replay

- Lock file `$logdir/<canon>.checks.lock` (created empty; `ns_private_dir "$logdir"` first). `start=$(date +%s)` is taken before locking. Open it with `exec {lfd}>"$lockf"`; try `flock -n "$lfd"`. When busy: print to stderr `checks: another run of <canon> in <dir> is in progress; waiting`, set `waited=1`, then `flock -w 3600 "$lfd"`; on timeout print to stderr `checks busy: <canon> in <dir> is still locked after 3600 s` and `exit 1` (never a pass).
- The check commands do **not** inherit the lock: `loop_checks_body` gets the fd number as its fifth argument and runs `ns_profile_checks_run ... {lfd}>&-` (D7). The lock is held by the `ns-conductor checks` process (its subshell) for as long as it waits for the checks. A process a check leaves running (a daemon, a detached test stub started under `setsid`) therefore never holds the lock, which matches the repo's rule in `bin/lib/pool.sh:51` and `bin/ns-conductor:267`. A lock held by a dead process is released by the kernel; there are no PID files and no age heuristics.
- Replay: only when `waited=1`, not `--force`, `clean=1`, `$logdir/<canon>.checks.json` exists, its `tree`, `target` and `checks_sha` equal `key`'s, its `finished_epoch >= start`, and either its `rc != 0` or its `cacheable == true` (a PASS from a dirty or changing tree is never replayed; the waiter runs the checks itself). Then print `checks: result of the concurrent run on tree <tree>: PASS` (rc 0) or `...: FAIL` (rc not 0), then each line of its `results`, then on FAIL `tail -n 40 "$logdir/<canon>.checks.log"`, and `exit <its rc>`.

### D5. Wrong-target warning (`loop_checks_warn <canon> <dir>`)

All output on stderr; it always returns 0.

1. `git -C "$dir" fetch -q origin`; on failure print `checks: could not fetch origin; target check skipped` and return.
2. `head=$(git -C "$dir" rev-parse HEAD)`, `br=$(git -C "$dir" rev-parse --abbrev-ref HEAD)`, `feature=$(lg get "$ledger" '.feature_branch // empty')`.
3. Refs to compare:
   - `<canon>` is `feature`: `origin/$feature` when `feature` is set; plus `origin/$(ns_branch_name "$(jq -r '.git.phase_branch' <<<"$profile")" "$id" "$p")` for every phase id `p` of `lg get "$ledger" '[.phases[] | select(.state != "merged") | .id | select(test("^fix-[0-9]+$") | not)] | join(" ")'` (a board fix round `fix-<n>` left unmerged is an open item, not missing code). When `feature` is set and differs from `br`, print `warning: <dir> is on <br>, but the run's code branch is <feature>`.
   - Otherwise: `origin/<phase branch of canon>`.
4. For each ref: `sha=$(git -C "$dir" rev-parse -q --verify "$ref^{commit}")` or skip it when it does not exist; when `git -C "$dir" merge-base --is-ancestor "$sha" HEAD` fails, print `warning: <dir> HEAD (<br> <first 12 of head>) does not contain <ref> <first 12 of sha>`.

### D6. Cache

- Store: `$logdir/<canon>.checks.json`, written with `jq -n` to a temp file in `$logdir` and `mv -f`. Fields: `tree` (string), `target` (canon), `checks_sha` (string), `rc` (number), `cacheable` (boolean), `head` (commit SHA at the end of the run), `finished` (`ns_now`, for display), `finished_epoch` (`date +%s`, number), `results` (array of the stdout lines of `ns_profile_checks_run`). The names avoid the `*.checks.log` and `*.checks.rc` globs of `bin/lib/runs.sh` and `bin/lib/report_logs.py`. No ledger change; an absent or unparsable file is a miss.
- `loop_checks_key <dir> <canon>` prints compact JSON `{"tree": <git -C dir rev-parse HEAD^{tree}>, "target": <canon>, "checks_sha": <sha256 hex of (jq -cS '.checks // []' <<<"$profile")>}`; it dies when `rev-parse` fails.
- `loop_wt_clean <dir>`: `s=$(git -C "$dir" status --porcelain) || return 1; [ -z "$s" ]` (staged, unstaged and untracked non-ignored files all count as dirty; a git failure counts as dirty).
- Hit: not `--force`, `clean=1`, stored `tree`/`target`/`checks_sha` equal `key`'s, stored `rc == 0` and `cacheable == true`. Then print `checks: cached PASS for tree <tree> (<canon>, <finished>); --force reruns`, then each line of `results`, run nothing, leave the log untouched and exit 0 (the rc marker gets 0).
- Before a run: `rm -f` the json, so a run killed half-way leaves a miss.
- Record after a run: `cacheable` is true only when `clean=1` before the run, `loop_wt_clean` succeeds after it and `HEAD^{tree}` is unchanged. A failure is recorded too (for replay) but never hits, because a hit needs `rc == 0`.
- Comparisons use `jq -e` on the file; a jq error is a miss.

### D7. Run

`loop_checks_body <canon> <dir> <key> <clean> <lockfd>`, called from the subshell of `loop_checks` as `loop_checks_body "$canon" "$dir" "$key" "$clean" "$lfd"`; it starts with `local lfd="$5"`:

1. `log="$logdir/<canon>.checks.log"`; `res=$(mktemp "$logdir/.checks-res.XXXXXX")`; `rm -f "$logdir/<canon>.checks.json"`.
2. `rc=0; ns_profile_checks_run "$dir" "$profile" "$log" >"$res" {lfd}>&- || rc=$?`. The `{lfd}>&-` redirection closes the lock fd for the call and every process it starts (bash closes the fd whose number is in `$lfd`; verified on ns-main), so no check command inherits the lock.
3. `cat "$res"`; when `rc != 0`, `tail -n 40 "$log"`.
4. Record (D6) with `results` from `$res`; `rm -f "$res"`; return `rc`.

The PASS/FAIL/SKIP lines now appear after all checks ran instead of one by one; this is accepted.

### D8. `stack-base` merges the base and pushes

- New helper `loop_stack_merge <dir> <branch> <stacked> <note>`: `git -C "$dir" fetch -q origin "$branch" || ns_die "could not fetch origin $branch"`. When `git -C "$dir" merge-base --is-ancestor "origin/$branch" HEAD` succeeds, return 0 (nothing to merge, nothing pushed). Otherwise, in this order: the existing uncommitted-changes check (`ns_die "the worktree $dir has uncommitted changes: commit them before stacking"`), the existing untracked-clash check against `HEAD...origin/$branch`, then `git -C "$dir" merge --no-ff -q -m "Merge $branch into $own$note" "origin/$branch"` (`own` = current branch). On conflict with `MERGE_HEAD` present: `lg set "$ledger" ".stacked_on = $(jstr "$stacked")"`, checkpoint, print `conflict merging <branch> into <own> in <dir>: resolve, commit and rerun the checks` to stderr, `exit 6` (as today). Other merge failure: `ns_die "could not merge $branch into $own in $dir"`. Before the merge, `pre=$(git -C "$dir" rev-parse HEAD)`. After a merge: `git -C "$dir" push -q origin "HEAD:refs/heads/$own" >/dev/null 2>&1`; when the push fails, `git -C "$dir" reset -q --hard "$pre"` (undo the merge, so the next `stack-base` sees the branch behind again and retries merge and push) and then `ns_die "could not push $own; the merge was undone"`.
- `conductor_stack_base`: replace the code from `if [ -z "$top" ]` (`:203`) to the end. First `[ -d "$dir" ] || ns_die "no code worktree for $id: run ns-conductor fix-branch or feature first"` (now also on the no-top path). No top: `loop_stack_merge "$dir" "$base" "$base" ""` (message `Merge main into fix/sbx-12`), then set `stacked_on` and `budget.integrate_from`, checkpoint, print `$base`. With a top: `loop_stack_merge "$dir" "$head" "$stacked" " (stacked on $stacked)"` (message unchanged), then set `stacked_on` and `integrate_from`, checkpoint, print `$head`. `integrate_from` is set only after the helper returned, so a fetch, merge or push failure never sets it.
- `budget.integrate_from`: unchanged semantics; the margin stays tied to `step == "integrate"` (Current state). No code change for it.
- Update the function comment: it merges the printed branch into the code branch when HEAD is behind it, and pushes the code branch after a merge.

### D9. Worker and implementer rule

- `bin/ns-conductor:402` becomes exactly: `printf '4. Run lint and only the tests covering the files you change (for example `bats tests/bats/<file>.bats`). Do not run the full suite: it runs through `ns-conductor checks` after you finish. The project'"'"'s checks, for reference:\n%s\n' "$checks"` (keep a `# shellcheck disable=SC2016` line above it for the backticks). The user-visible text is: `4. Run lint and only the tests covering the files you change (for example `bats tests/bats/<file>.bats`). Do not run the full suite: it runs through `ns-conductor checks` after you finish. The project's checks, for reference:` followed by the checks.
- `plugins/ns/agents/implementer.md` step 4 becomes: `4. Run lint and only the tests covering the files you change (for example one test file, not the whole suite). Do not run the full suite: it runs through \`ns-conductor checks\` after you finish.` Stop condition "Checks still fail after a good-faith fix" becomes "The tests you ran still fail after a good-faith fix". Outputs: "followed by the tests you ran with results".

### D10. Skill flow (`/ns:run`, `/ns:implement`, integrator, `/ns:dod`)

- New **Sync** procedure, run by the conductor in its own session (not a subagent): `ns-conductor stack-base <id>`. Exit 0: keep the printed branch as `<pr-base>`. Exit 6: `git -C <code worktree> merge --abort`, `ns-conductor note <id> "stack-base conflict before review; the integrator resolves it"`, use `<pr-base>` = `<base>`. Exit 7: Escalate. Exit 4: end the session (the run waits at gate 1.5). Any other non-zero exit (for example `could not push`): Escalate with its output. Then `ns-conductor checks <id> feature`, following the waiting rule of Start step 4 (foreground only when the Bash timeout bounds it; otherwise background it after removing `logs/<id>/feature.checks.rc` and wait for that file). A `warning:` line in its output means the checked worktree lacks pushed code: Escalate with the line, even when the checks passed.
- Where Sync runs: T0 after the implementer (between today's steps 2 and 3, so the checks of step 3 are the Sync checks); T1 after implementer step B and before the code reviewer; T2/T3 when every phase is merged, after setting `step=board` and before the board. On a resumed session that does not know `<pr-base>`, run `stack-base` again (it is idempotent).
- Failing Sync checks: T0 as today's step 3 loop; T1 launch `ns:implementer` with the output and rerun `ns-conductor checks <id> feature`, up to `budgets.T1.review_rounds` times, then Escalate; T2/T3 the failing output becomes a blocking board finding (`RUN/board-fix-<n>.md`).
- T1 verdict `changes`: after the implementer fixes, run `ns-conductor checks <id> feature`, then review again.
- Diff base: the T1 code reviewer and every board reviewer read `git diff origin/<pr-base>...origin/<feature>` (was `origin/<base>`).
- Every implementer launch says: run only the tests covering the files you change; the full suite runs through `ns-conductor checks`.
- Integrator: step 0 still runs `stack-base` (idempotent; refreshes `integrate_from`; catches a newly opened stack top). Its step 1 base merge is removed. After an exit-6 resolution it commits and pushes; it no longer calls `checks` itself, because `/ns:dod` (next step) gets the profile checks from `ns-conductor checks <id> feature`, which is a cache hit when stack-base changed nothing and a rerun when it did. It never runs the test command directly and never calls `checks <id> fix`.
- `/ns:dod` inside a run (`NS_RUN_ID` set): instead of running the profile's `checks` entries one by one, it gets them from `ns-conductor checks "$NS_RUN_ID" feature`, run once: remove `~/.config/ns/logs/<id>/feature.checks.rc` (the path `ns-conductor checks` documents), start the call in the background with its stdout and stderr to a temporary file, wait for the `.rc` file to appear (as `/ns:run` Start step 4 says: never `pgrep`/`ps` loops), then read the file. One row per `PASS|FAIL|SKIP <stack> <name>` line (Detail `cached, tree <sha>` when it printed `checks: cached PASS for tree <sha>`); every `warning:` line becomes a FAIL row `checked tree is stale` with the warning as Detail; rc 4: report the budget stop and end; rc 1 with no PASS/FAIL lines (for example `checks busy`): one FAIL row with the output. Then run `commands.typecheck`, `commands.audit` and the further `docs.dod` commands as today. Outside a run nothing changes.
- `/ns:run` Integrate step 2 exit 6 clause becomes: "exit 6: it resolves the conflicts, commits and pushes (the checks then run in `/ns:dod`), or escalates at gate 1.5 and opens no PR". The integrator's stop condition "or the checks are red after resolving them" becomes "or `/ns:dod` reports a failing check after resolving them", and `/ns:dod` reporting a `checked tree is stale` row is a stop condition (gate 1.5, no PR).

### D11. Deliberate refinements of `RUN/design.md`

- Lock fd: the design let the check commands inherit the lock so an orphaned check of a killed caller would still block. The plan closes it for the checks (D4, D7): an inherited fd is held by any daemon or detached process a check starts (this repo's own suite starts `setsid` worker stubs), which would make every later call wait 3600 s and fail. `bin/lib/pool.sh:51` already states this rule. Cost: an orphaned check of a killed caller no longer blocks a second copy; the ns-x4 overlaps came from direct `bats` calls, which D9 and D10 remove.
- Replay only for calls that waited on the lock, and a PASS only when it was recorded cacheable (D4): with `NS_NOW` in tests or second-resolution times a sequential call could otherwise replay, and a PASS of a dirty tree must never be reported for a clean one.
- Cache record adds `finished_epoch` and `results` (D6) for the replay comparison and so a hit can print the per-check lines `/ns:dod` needs.
- `stack-base` undoes its merge when the push fails (D8), so a retry pushes; the design only said the push failure must die before `integrate_from` is set.
- T0 Sync runs before the step-3 checks instead of after them, so a T0 run checks once instead of twice; T0 has no review in between.
- The integrator does not call `checks` itself after stack-base; `/ns:dod` does, through the cache (D10). The effect is the design's: a rerun only when the tree changed.
- `/ns:dod` turns `warning:` lines into FAIL rows and waits through the marker file (D10), so a stale tree is never reported green and a 15-minute suite is not killed by the Bash timeout.

### Tests

New tests go into `tests/bats/conductor-loop.bats` (checks) and `tests/bats/stack-pr.bats` (stack-base); each new test name ends with `(ns-x5)`. A check command that counts its runs appends to a file outside the worktree, for example `set_test_cmd "echo x >>$BATS_TEST_TMPDIR/count"`, and the count is `wc -l <"$BATS_TEST_TMPDIR/count"`. The test-architect's acceptance tests, if any, live in these two files with the expected-failure marker named in `RUN/test-strategy.md`.

### Rejected alternatives

- PID or mtime lock files: need stale detection and race; `flock` is already used for `budget.lock`.
- Cache keyed by HEAD commit: a merge or rebase with the same tree would miss; tree SHA plus a clean worktree is exact.
- Cache inside the worktree or the ledger: changes `git status` or the tree, or bloats the ledger.
- A new subcommand for the base merge: more surface than extending `stack-base`, which already owns merges into the code branch.
- A new field for the integrator margin: `step == "integrate"` already gives it.
- Replaying for every call that finds a fresh result: with `NS_NOW` or second-resolution times a sequential call could replay instead of running; replay is limited to calls that actually waited on the lock.

## ADRs

None. The lock and cache are local, additive and reversible (delete `<canon>.checks.json`, or pass `--force`); they move no trust boundary and change no release path. The rationale is recorded in `docs/conductor.md` `### checks` and the CHANGELOG entry.

## Manual steps

None. `manual_before` and `manual_after` are empty, so there is no `RUN/manual-steps.md`.

## Risks and open questions

- Existing tests that run `checks` twice on the same tree and profile and expect a second run would now see a cache hit. A scan found none (`tests/bats/conductor-loop.bats:174` changes the profile between runs, which changes `checks_sha`). If a worker finds one, it adds `--force` to the second call only when the test's intent is "reruns"; if the intent is unclear, stop with `status=blocked`. Never delete or weaken a test.
- `stack-base` now dies without a code worktree also when no run PR is open. All callers in tests run `fix-branch` first. If any other test or e2e scenario fails on `no code worktree`, stop with `status=blocked` naming it.
- `stack-pr.bats` "stack-base records the profile's base branch, not main" (`:186`) uses base `develop`, which does not exist on origin; the new fetch would die. The brief updates the test to push a `develop` branch first; that is a fixture fix, not a weakened assertion.
- A check that leaves untracked non-ignored files makes the tree dirty, so the cache never hits there (safe, only slow). Documented in `docs/conductor.md`.
- Waiters hold the Bash tool for up to the suite's length; the existing marker-file waiting rule (`/ns:run` Start step 4) still applies.
- Per phase the suite still runs on the phase tree (`checks <id> <phase>`) and again on the merge tree (`merge`); these are two trees, so this is within "once per tree and target" and out of scope.
- The ns-x4 cause (Current state) must reach the PR (AC-4). No phase can write `RUN/notes.md` (it lives on `plan/ns-x5`, outside the feature worktree), so the conductor records it with `ns-conductor note ns-x5 "<the cause, one line>"` right after `ns-conductor feature ns-x5` (gate 1 approved), before the first phase starts; it then lands in the PR's Follow-ups. `final_checks` repeats it.
- `conductor_merge` merges in the feature worktree before `loop_checks` takes the lock, so it can change the tree under a running explicit `checks feature`. D6's rule (cacheable only when the tree and cleanliness are unchanged after the run) keeps the cache safe; `docs/conductor.md` says so.
- No owner decisions are open.

## Implementation manifest

The phases run one after another: p2 changes `bin/lib/conductor-loop.sh` and `docs/conductor.md` after p1. p1 holds only the concurrency-sensitive checks work (lock, replay, cache, warning); p2 holds the small `stack-base` change and the prose that describes the new flow.

```yaml
plan_slug: ns-x5
feature_branch: feature/x5
max_parallel: 2
manual_before: []
manual_after: []
verify_after_merge: ["tests/lint", "tests/docs-check"]
final_checks:
  - "docs/ns-x5-plan.md is deleted on feature/x5"
  - "CHANGELOG.md [Unreleased] has an ns-x5 entry"
  - "grep -n 'bats' plugins/ns/agents/integrator.md prints nothing"
  - "RUN/notes.md (and so the PR body's Follow-ups) states the ns-x4 cause from the plan's Current state section"
  - "bats --jobs \"$(nproc)\" tests/bats passed once through ns-conductor checks ns-x5 feature"
phases:
  - id: p1-checks-cache
    title: Lock, cache, --force, canonical target and wrong-target warning for ns-conductor checks
    depends_on: []
    complexity: M
    touches:
      - bin/lib/conductor-loop.sh
      - tests/bats/conductor-loop.bats
      - docs/conductor.md
    brief: |
      Read the plan's Design subsections D1 to D7, D11 and Tests first; every name, string and order is there. Do not touch conductor_stack_base (phase p2 changes it).
      If RUN/test-strategy.md lists acceptance tests for AC-1 to AC-4 in tests/bats/conductor-loop.bats with an expected-failure marker, remove the markers of those tests and make them pass; never weaken them. Add the tests below that are still missing.
      1. bin/lib/conductor-loop.sh: rewrite loop_code_wt as in D1 (feature_branch first, tier fallback) and add loop_checks_canon (D1).
      2. Add loop_wt_clean, loop_checks_key (D6) and loop_checks_warn (D5) as functions next to loop_checks.
      3. Rewrite loop_checks as `loop_checks <target> [--budget] [--force]` following D3 exactly, with the lock and replay of D4 and the cache hit of D6, all inside the existing subshell; the rc marker stays under the caller's target name.
      4. Rewrite loop_checks_body as `loop_checks_body <canon> <dir> <key> <clean> <lockfd>` per D7 (the `{lfd}>&-` redirection on the ns_profile_checks_run call, the record step of D6 with temp file + mv).
      5. conductor_checks: accept the optional third argument `--force` (D2) and pass it on to `loop_checks "$2" --budget`. Update conductor_loop_usage to `checks        <id> <phase|feature> [--force]` and the ns_usage text to `ns-conductor checks <id> <phase|feature> [--force]`. Leave conductor_merge's `loop_checks feature` call as it is.
      6. tests/bats/conductor-loop.bats, add (each name ends with "(ns-x5)"; background processes are started with `3>&-` so bats does not wait on them; every sbx-12 test starts with `commit_plan; ns-conductor feature sbx-12 >/dev/null`, as the existing checks tests do, because setup() creates no feature worktree):
         a. lock: `set_test_cmd "echo x >>$BATS_TEST_TMPDIR/count; sleep 3"`; start `ns-conductor checks sbx-12 feature >"$BATS_TEST_TMPDIR/a.out" 2>&1 3>&- &`, poll (up to 20 s, `sleep 0.1`) until the count file exists, then `run ns-conductor checks sbx-12 feature`; `ra=0; wait "$pid" || ra=$?`; assert count == 1, both exit 0, output contains "another run of feature".
         b. same with `...; sleep 3; false`: count == 1, both exit 1, the second's output contains "result of the concurrent run on tree" and "FAIL".
         c. no lock leak: `set_test_cmd "setsid sleep 30 </dev/null >/dev/null 2>&1 3>&- & echo \$! >$BATS_TEST_TMPDIR/sleep.pid; echo x >>$BATS_TEST_TMPDIR/count"`; run checks (success); then, while that sleep still runs, `flock -n "$NS_CONFIG_DIR/logs/sbx-12/feature.checks.lock" true` succeeds; finally `kill "$(cat "$BATS_TEST_TMPDIR/sleep.pid")"`.
         d. stale lock: `( exec 9>"$lockf"; flock 9; exec sleep 60 ) 3>&- &` on `$NS_CONFIG_DIR/logs/sbx-12/feature.checks.lock` (mkdir -p its directory first), wait until `flock -n "$lockf" true` fails, `kill -9` the background pid, `wait` it ignoring the status; then `run ns-conductor checks sbx-12 feature`: success, count == 1, output does not contain "waiting".
         e. cache hit: run checks twice with the counting command; second: success, count still 1, output contains "cached PASS for tree $(git -C "$FWT" rev-parse 'HEAD^{tree}')", and `feature.checks.rc` holds 0.
         f. cache miss, one test each: a new commit in "$FWT" (count 2); an earlier failure (`...; false`, run twice: count 2, both exit 1); `--force` (count 2); after a pass, an untracked file created in "$FWT" (count 2); after a pass, a modified tracked file (`printf x >>"$FWT/README.md"`, count 2); a pass made while an untracked file was present is not cacheable: remove the file, call again, it reruns (count 2).
         g. canonical fix: T1 run sbx-13 (`"$NS_REPO_ROOT/bin/ns" new sbx-13 --tier T1 --yes`, `ns-conductor fix-branch sbx-13`), checks feature passes, then `checks sbx-13 fix` is a cache hit (count unchanged), writes `fix.checks.rc` = 0 and creates no `fix.checks.log`.
         h. loop_code_wt: T1 run sbx-13 after fix-branch, `ns-ledger set "$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-13/.nightshift/runs/sbx-13/ledger.yaml" '.tier = "T2"'`, `checks sbx-13 feature` runs in the `--fix` worktree (copy the cwd assertion of the test "checks prints PASS lines and runs in the --fix worktree for T1").
         i. wrong target: T1 run sbx-13 after fix-branch; in a separate clone of "$BARE": `git checkout -q -b fix/sbx-13 origin/main`, commit one file, `git push -q origin fix/sbx-13`; `run ns-conductor checks sbx-13 feature`: output contains "warning:" and "does not contain origin/fix/sbx-13". A second test: a T1 run with nothing pushed prints no "warning:".
         j. merge prints no "warning:" (copy the setup of the test "merge makes a --no-ff merge with the trailer, ..." and assert on the merge output).
         k. `ns-conductor checks sbx-12 feature --bogus` exits 2.
      7. docs/conductor.md: rewrite `### checks` (usage with [--force]; `fix` counts as `feature` for T0/T1; the lock, the waiting line, the 3600 s timeout, that checks do not inherit the lock, stale locks; replay; the cache key, the store `logs/<id>/<canon>.checks.json` and its fields, the invalidation cases of AC-3, that untracked files a check leaves behind prevent hits, that a merge under a running check makes its pass uncacheable; `--force`; the warning lines, and that merge's internal call does not warn); the budget-check paragraph at line 102 (the integrator's call is `checks <id> feature`, or `fix` for T0/T1); the logs table: drop the duplicate `<target>.checks.log` row and add `<canon>.checks.json` and `<canon>.checks.lock`.
      8. Run tests/lint, `bats tests/bats/conductor-loop.bats tests/bats/budget.bats` and tests/docs-check. Do not run the full suite.
      Stop conditions: an existing test fails because of the cache and its intent is unclear (plan, Risks); a test needs a file outside touches; `flock` or `setsid` is missing: stop with status=blocked.
    acceptance:
      - "tests/lint exits 0"
      - "bats tests/bats/conductor-loop.bats exits 0"
      - "bats tests/bats/budget.bats exits 0"
      - "grep -c '(ns-x5)\" {' tests/bats/conductor-loop.bats prints at least 16"
      - "grep -n '{lfd}>&-' bin/lib/conductor-loop.sh prints a line"
      - "grep -n 'checks.json' docs/conductor.md and grep -n -- '--force' docs/conductor.md each print a line"
      - "tests/docs-check exits 0"
  - id: p2-stack-base-flow
    title: stack-base merges the base and pushes; Sync before review; touched-tests-only guidance; integrator and /ns:dod use ns-conductor checks
    depends_on: [p1-checks-cache]
    complexity: M
    touches:
      - bin/lib/conductor-loop.sh
      - bin/ns-conductor
      - tests/bats/stack-pr.bats
      - tests/bats/budget.bats
      - plugins/ns/skills/run/SKILL.md
      - plugins/ns/skills/implement/SKILL.md
      - plugins/ns/agents/implementer.md
      - plugins/ns/agents/integrator.md
      - plugins/ns/skills/dod/SKILL.md
    brief: |
      Read the plan's Design subsections D8, D9, D10 and D11 first; the texts and the order are there. Change only conductor_stack_base and the new loop_stack_merge in bin/lib/conductor-loop.sh.
      If RUN/test-strategy.md lists acceptance tests for stack-base in tests/bats/stack-pr.bats with an expected-failure marker, remove their markers and make them pass; never weaken them.
      1. bin/lib/conductor-loop.sh: add loop_stack_merge and change the end of conductor_stack_base as in D8 (the push-failure reset included); update its comment.
      2. tests/bats/stack-pr.bats: in "stack-base records the profile's base branch, not main" push a develop branch first: `git -C "$clone" push -q origin "$(git -C "$CODE_WT" rev-parse HEAD):refs/heads/develop"` before the profile commit. In "stack-base with one open run PR prints its branch, merges it and records its run id" add `[ "$(git -C "$REMOTE" rev-parse refs/heads/fix/sbx-12)" = "$(git -C "$CODE_WT" rev-parse HEAD)" ]`. Add (names end "(ns-x5)"):
         a. no open run PR and origin/main one commit ahead (`w=$(mktemp -d "$BATS_TEST_TMPDIR/m.XXXXXX"); git clone -q "$REMOTE" "$w"; printf 'x\n' >"$w/new.txt"; git -C "$w" add new.txt; git -C "$w" commit -q -m new; git -C "$w" push -q origin HEAD:main`; tests c and d move origin/main the same way): output `main`; `git -C "$CODE_WT" merge-base --is-ancestor origin/main HEAD` succeeds; `git -C "$CODE_WT" rev-list --merges --count HEAD~1..HEAD` is 1; `git -C "$REMOTE" rev-parse refs/heads/fix/sbx-12` equals `git -C "$CODE_WT" rev-parse HEAD`; `.budget.integrate_from` equals "$NS_NOW".
         b. up to date: output `main`, no merge commit, and `git -C "$REMOTE" rev-parse -q --verify refs/heads/fix/sbx-12` fails (nothing pushed).
         c. origin/main has a conflicting README.md change and the code branch has its own README.md commit: exit 6, MERGE_HEAD present, stacked_on main, `.budget.integrate_from // "none"` is none.
         d. push refused: origin/main one commit ahead, then `printf '#!/bin/sh\nexit 1\n' >"$REMOTE/hooks/pre-receive"; chmod +x` it; stack-base fails, output contains "could not push", `git -C "$CODE_WT" rev-parse HEAD` equals the pre-call HEAD, integrate_from none; then remove the hook, run stack-base again: success and the remote fix/sbx-12 equals the code worktree HEAD, which contains origin/main.
      3. tests/bats/budget.bats: change only if a test fails because of D8; such a change may only add fixture setup.
      4. bin/ns-conductor: replace the rule 4 printf (line 402) with the D9 text exactly (keep `# shellcheck disable=SC2016` directly above it), and the closing line at line 414 with `printf 'then the tests you ran with their results, and anything you could not do.\n'`.
      5. plugins/ns/agents/implementer.md: step 4, the Outputs line and the stop condition as in D9.
      6. plugins/ns/skills/run/SKILL.md:
         a. Add a "## Sync" section after "## T3" and before "## Review board" with the D10 Sync procedure: exit codes, the waiting rule, the `warning:` rule, and the failing-checks rule per tier.
         Inserting steps shifts the numbers: renumber each section and update every cross-reference inside it (for example T1's "repeat from step 5" must point to the code-reviewer step).
         b. T0: insert a step "Sync" after step 2; the checks step keeps its loop and says the Sync checks are its first run.
         c. T1: step 3: the implementer adds the failing test and runs only that test to see it fail; step 4: the implementer makes the tests covering the change pass; insert a step "Sync" after step 4 with the T1 failing-checks rule of D10; the code-reviewer step's diff becomes `git diff origin/<pr-base>...origin/<feature>`; the review-round step's verdict `changes`: after the implementer, `ns-conductor checks <id> feature`, then the code-reviewer step again.
         d. T2 step 9: after setting `step=board`, run Sync, then Review board, then Integrate.
         e. Review board step 1: diff `git diff origin/<pr-base>...origin/<feature>`.
         f. Integrate step 2: the exit 6 clause as D10 says; replace "It then merges `origin/<base>` if behind, runs `/ns:dod` to write `RUN/dod.md`," with "stack-base merges the base branch when the code branch is behind and pushes it. It then runs `/ns:dod` to write `RUN/dod.md` (inside a run `/ns:dod` takes the profile checks from `ns-conductor checks <id> feature`, a cache hit when nothing changed); it never runs the test command directly,".
         g. Start step 4 waiting rule: add "The full suite runs only through `ns-conductor checks`; implementers run only the tests covering their files."
      7. plugins/ns/skills/implement/SKILL.md: section 3 step 2: add "Workers ran only the tests covering their files; this is the phase's full-suite run."; section 5: run the Sync procedure of `/ns:run` after setting `step=board` and before the board, and change the diff to `git diff origin/<pr-base>...origin/<feature>`.
      8. plugins/ns/agents/integrator.md: delete step 1 (the base merge) and renumber; step 0 exit 6 ends with "Resolve the conflicts, commit the merge and push; the checks run in `/ns:dod`." (no checks call); the `/ns:dod` step says it takes the profile checks from `ns-conductor checks <id> feature`, that the integrator never runs the test command itself and never calls `ns-conductor checks <id> fix`, and that a `checked tree is stale` row is a stop condition; step 0's sentence "It prints the profile base branch when no other run PR is open; otherwise it merges the top open run PR's branch into the code branch (never a rebase) and prints that branch." also says that it merges the base branch when the code branch is behind it and pushes the code branch after any merge; the description line drops "merges the base"; the stop conditions as D10 says ("The merge of the base conflicts semantically" now refers to the stack-base merge). The file must not contain the word bats.
      9. plugins/ns/skills/dod/SKILL.md: add the in-run rule of D10 to section 1 step 3 and section 2 (background call, marker file, rows, warning rows, exit 4, busy).
      10. Run tests/lint, tests/docs-check and `bats tests/bats/stack-pr.bats tests/bats/budget.bats tests/bats/conductor.bats tests/bats/hooks.bats`. Do not run the full suite.
      Stop conditions: a stack-base test other than the develop one fails because the code worktree is missing or because of the new push; a bats test asserts the old rule 4 text; a skill step you must change is not where the plan says: stop with status=blocked.
    acceptance:
      - "tests/lint exits 0"
      - "bats tests/bats/stack-pr.bats tests/bats/budget.bats tests/bats/conductor.bats tests/bats/hooks.bats exits 0"
      - "grep -c '(ns-x5)\" {' tests/bats/stack-pr.bats prints at least 4"
      - "grep -n 'bats' plugins/ns/agents/integrator.md prints nothing"
      - "grep -n 'only the tests covering the files you change' bin/ns-conductor plugins/ns/agents/implementer.md prints a line for each file"
      - "grep -n '## Sync' plugins/ns/skills/run/SKILL.md prints one line"
      - "grep -n 'origin/<pr-base>...origin/<feature>' plugins/ns/skills/run/SKILL.md plugins/ns/skills/implement/SKILL.md prints at least one line per file"
      - "grep -n 'ns-conductor checks' plugins/ns/skills/dod/SKILL.md and grep -n 'stale' plugins/ns/skills/dod/SKILL.md each print a line"
      - "grep -n 'merges .origin/<base>. if behind' plugins/ns/skills/run/SKILL.md plugins/ns/agents/integrator.md prints nothing"
      - "tests/docs-check exits 0"
  - id: p3-retire
    title: Reference docs for stack-base, the worker prompt and the flow; changelog; retire the plan
    depends_on: [p1-checks-cache, p2-stack-base-flow]
    complexity: S
    touches:
      - docs/conductor.md
      - docs/usage.md
      - docs/agents.md
      - CHANGELOG.md
      - docs/ns-x5-plan.md
    brief: |
      Read the plan's Design subsections D8, D9 and D10 first. No code changes in this phase.
      1. docs/conductor.md `### stack-base`: it merges `origin/<printed branch>` into the code branch when HEAD is behind it (also the base branch when no run PR is open), pushes the code branch after a merge, undoes the merge when the push fails, dies without a code worktree, and sets `integrate_from` only after success. Replace the sentence "After resolving, the caller commits and reruns `checks <id> feature`." with "After resolving, the caller commits and pushes; the checks then run in `/ns:dod`."
      2. docs/conductor.md "## The worker prompt": replace rule 4 with the D9 user-visible text, and add after the feedback block the closing lines the prompt prints: "End your final message with one line:", "PHASE-REPORT <phase> status=<done|blocked> head=<sha of HEAD after your push>" and "then the tests you ran with their results, and anything you could not do." (check them against bin/ns-conductor).
      3. docs/usage.md: the stacking paragraph (line 107): stack-base also merges the base branch when the code branch is behind and pushes it, runs at the end of implement before review, and again in integrate; replace "resolved by the integrator, which reruns the checks" with "resolved by the integrator; the checks then run in `/ns:dod`". The `/ns:dod` paragraph (line 344): inside a run it takes the profile checks from `ns-conductor checks <id> feature`.
      4. docs/agents.md: the integrator entry (line 84): replace "it resolves and rechecks" with "it resolves, commits and pushes; the checks run in `/ns:dod`", and add that it no longer merges the base itself and runs no test command directly; the implementer entry, if it names checks: it runs only the tests covering its files.
      5. Read docs/conductor.md `### checks` against bin/lib/conductor-loop.sh on the feature branch; fix any mismatch in wording only.
      6. CHANGELOG.md, under `## [Unreleased]`: add a `### Changed` heading below the existing `### Fixed` block (keep the existing entries) with one bullet: `ns-conductor checks` takes a per-worktree lock (a second call waits and reports the first call's result), caches a pass by tree SHA, canonical target and the profile's checks (`logs/<id>/<canonical target>.checks.json`; a dirty worktree, a changed tree, a failure or `--force` reruns), treats `fix` as `feature` for T0/T1, and warns on stderr when the worktree's HEAD lacks the run's pushed code branch or an unmerged phase branch; `stack-base` also merges the base branch when the code branch is behind and pushes it, and runs at the end of implement, before review; workers run only the tests covering their files, and the integrator and `/ns:dod` get the full suite from `ns-conductor checks` (ns-x5).
      7. Delete docs/ns-x5-plan.md (`git rm`).
      8. Run tests/lint and `tests/docs-check --final`.
    acceptance:
      - "test ! -e docs/ns-x5-plan.md"
      - "grep -n 'ns-x5' CHANGELOG.md prints a line in the [Unreleased] section"
      - "grep -n 'only the tests covering the files you change' docs/conductor.md prints one line"
      - "grep -n 'reruns the checks\\|resolves and rechecks\\|reruns .checks <id> feature.' docs/usage.md docs/agents.md docs/conductor.md prints nothing"
      - "tests/docs-check --final exits 0"
      - "tests/lint exits 0"
```

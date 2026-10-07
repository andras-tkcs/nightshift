# Review: ns-x5 phase p1-checks-cache, round 1

Range: `git diff origin/feature/x5...origin/feature/x5--p1-checks-cache` (head 14c5db4c0d9544e651e7be874fdee6655cd2ee8b). Inputs: docs/ns-x5-plan.md (D1-D7, D11, Tests, manifest entry p1-checks-cache), RUN/test-strategy.md. Project checks not run (not requested).

## Findings

- non-blocking · bin/lib/conductor-loop.sh:371 · The subshell runs as `( ... ) || rc=$?`, so errexit is off inside it. If `loop_checks_key` hits its `ns_die` (it fails inside a command substitution), `key` stays empty and the checks still run. The record step's `jq --argjson k ""` then fails and nothing is stored. This is safe, because no false pass is possible, but the die message is lost. The same applies to `canon=$(...)` and `dir=$(...)`. · Make the failures explicit: `key=$(loop_checks_key "$dir" "$canon") || exit 1`, and do the same for `canon` and `dir`.
- non-blocking · tests/bats/conductor-loop.bats:929,950 · The lock tests' check command sleeps 10 s instead of the 3 s the brief and test strategy name. Every assertion is unchanged. The longer hold makes the race more robust, because the second call fetches origin before it locks. It is not a weakening, but it adds about 14 s to the suite and differs from the brief. · Mention the deviation in the PR body. Optionally drop the sleep to 5 s if 10 s is not needed.
- non-blocking · bin/lib/conductor-loop.sh:310 · `loop_checks_warn` uses `(.phases // [])` where D5 says `.phases[]`. This is a harmless hardening for ledgers without phases (T0/T1). · None needed; note it in the PR body as a refinement.
- non-blocking · docs/conductor.md:145 · "`ns stack merge`" was reworded to "The stack merge command of `ns`". This is unrelated to the brief, probably to satisfy docs-check. · Fine as is; keep it if docs-check requires it.

## Summary

The implementation follows D1-D7:
- `loop_code_wt` decides from `feature_branch` first and falls back to the tier.
- `loop_checks_canon` maps `fix` to `feature` only when both name the same worktree.
- `loop_checks` keeps the D3 order inside the subshell: canon, budget, dir, warn, lock, clean/key, replay, cache, run.
- The lock: it has a non-blocking probe, the waiting line, `flock -w 3600`, and the timeout line with exit 1.
- The check commands do not inherit the lock: `{lfd}>&-` is set on the `ns_profile_checks_run` call.
- Replay: it happens only for a call that waited and needs a clean tree, the same key and `finished_epoch >= start`. A PASS is replayed only when it was cacheable.
- Cache: a hit needs rc 0 and cacheable. The json is removed before a run and written through temp + mv. `cacheable` requires a clean tree before and after the run and an unchanged tree.
- The rc marker keeps the caller's target name.
- `conductor_checks` accepts only `--force` as the third argument, and the usage texts are updated. `conductor_merge` is unchanged.
- `conductor_stack_base` is untouched, as the brief requires.

Tests: the acceptance cases were committed earlier on the feature branch with strict xfail markers. This phase removes the markers and the `ns_xfail` helper, and changes no assertion. The manifest grep (16 `(ns-x5)" {` cases) and the `{lfd}>&-` grep are met.

Docs: `docs/conductor.md` `### checks` covers everything the brief lists for it. The budget paragraph names `fix` for T0/T1. The logs table drops the duplicate row and adds `.checks.json` and `.checks.lock`.

Hygiene: only the three files in `touches` changed. No `.nightshift/` files and no secrets are in the diff. No untrusted text was copied in.

No blocking findings.

REVIEW verdict=approve head=14c5db4c0d9544e651e7be874fdee6655cd2ee8b

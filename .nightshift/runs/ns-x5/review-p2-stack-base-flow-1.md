# Review: p2-stack-base-flow, round 1

Range: `origin/feature/x5...origin/feature/x5--p2-stack-base-flow` (1 commit, 027f77c). Inputs: docs/ns-x5-plan.md (D8 to D11, manifest entry p2-stack-base-flow), review-checklist. I did not run the checks; the caller did not ask me to. I did not read any worker log.

## Findings

- non-blocking · tests/bats/stack-pr.bats:893 and :908 · In the conflict test and the push-refused test, the `.budget.integrate_from // "none"` = none assertions prove nothing. The run is not in state `running`, and `BUDGET_TX` in bin/ns-ledger:54 clears `integrate_from` whenever the state is not running, so these assertions would pass even if stack-base set `integrate_from` before the merge or push. The code is correct by construction: `lg set ... integrate_from` comes only after `loop_stack_merge` returns. Still, D8's "a fetch, merge or push failure never sets it" has no real test. · Add `ns-ledger state "$LEDGER" running --no-gate` at the start of both tests, as the phase already did for the first ns-x5 test at :857. This only adds fixture setup.
- non-blocking · tests/bats/stack-pr.bats:856-857 · The phase added a fixture line (`ns-ledger state ... running --no-gate`) to an acceptance test from the test-architect. This is outside the literal brief, which only said to remove the markers. It is justified: without it the `integrate_from = NS_NOW` assertion can never pass, for the same ledger reason. It adds setup only and weakens no assertion. · Mention it in the PR body under open items.
- non-blocking · plugins/ns/skills/run/SKILL.md:44 (T0 step 4) · "the checks of Sync are its first run" can be read as "run the checks again". · Say it directly, for example "Sync already ran the checks; when they passed, go on; on failure launch `ns:implementer` ...".
- non-blocking · plugins/ns/skills/run/SKILL.md:108 (Integrate step 2) · The long sentence "it never runs the test command directly, and, if the PR branch contains `.nightshift/`, runs ..." joins two unrelated clauses and is hard to parse. · Split it into two sentences.
- non-blocking · bin/lib/conductor-loop.sh:138 · The new comment line on conductor_stack_base is about 160 characters long, much longer than the lines around it. · Rewrap it.
- non-blocking · bin/lib/conductor-loop.sh:142 · `own`, `mout` and `clash` are still declared `local` in conductor_stack_base but are no longer used there. · Drop them from the `local` list.

## Summary

- **D8:** `loop_stack_merge` follows the plan step by step:
  - order: fetch, then the up-to-date return, then the uncommitted-changes check, then the untracked-clash check, then `pre`, then the merge;
  - conflict: exits 6 and records `stacked_on`;
  - a failed push: resets hard to `pre` and dies with "could not push ...; the merge was undone".
  - `conductor_stack_base` checks the worktree first and calls the helper on both paths (no top: message "Merge main into fix/..."; top: message unchanged). It sets `integrate_from` only after the helper returns. The comment is updated.
- **D9:** The rule 4 text in bin/ns-conductor and the closing line match exactly, and the SC2016 disable is kept. The implementer.md step 4, Outputs and stop condition match D9.
- **D10:**
  - run/SKILL.md has one `## Sync` section between T3 and Review board, with the exit codes, the waiting rule, the `warning:` rule and the failing-checks rule per tier.
  - T0 and T1 are renumbered, and the cross-references point to step 6 (the code reviewer).
  - The T1 `changes` loop reruns the checks.
  - T2 step 9 and the board use `<pr-base>`, and the Integrate step 2 text matches the brief.
  - implement/SKILL.md section 3 step 2 and section 5 are updated.
  - integrator.md: the base-merge step is removed, the steps are renumbered, the description no longer says "merges the base", the stop conditions are updated and the file does not contain "bats".
  - dod/SKILL.md has the in-run rule: background call, marker file, rows, `checked tree is stale`, exit 4, busy.
- **Tests:** The four ns-x5 acceptance tests from the test-architect had `ns_xfail` markers. The phase removed the markers and the helper, as the comment of that helper said it would, and weakened no assertion. The develop fixture fix and the push assertion in the one-PR test are as the brief says.
- **Scope:** budget.bats is unchanged. All changed files are in `touches`, there are no `.nightshift/` files, and nothing comes from untrusted text.
- **Docs:** The reference docs (conductor.md, usage.md, agents.md) belong to p3 under the plan.

There are no blocking findings. The two test findings would turn a vacuous assertion into a real one and are worth a one-line follow-up.

REVIEW verdict=approve head=027f77c186ca2bbb94780642e3fe3aac5c23ad36

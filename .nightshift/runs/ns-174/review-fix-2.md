# Review fix round 2: ns-174

Range: `origin/main...origin/fix/ns-174`, head 357f1fb79b6489263acffa7fa67a1abd733d576e. Judged against `RUN/mini-plan.md`, CLAUDE.md and docs/conductor.md. No worker log was offered. The caller did not ask for the project checks. I ran only the new cache-hit test and the ns-x6 test next to it (`bats -f 'ns-174|ns-x6' tests/bats/conductor-loop.bats`), and both pass.

## Findings

- non-blocking · tests/bats/conductor-loop.bats:1271 · The cache-hit test was added in the fix commit (357f1fb), after the behaviour it covers (20741f9), so it never failed first. Round 1 asked for this test as missing coverage of code that already existed, so this is accepted. · None needed. Mention it in the PR body.
- non-blocking · docs/conductor.md:155 · The risk-check section still says the conductor "names in the run's ntfy line", while run/SKILL.md:90 now gives the exact `ns-notify "ns: <id> risk floor <T> is above owner tier <tier>"` call. · Use the same wording in docs/conductor.md, or point to the run skill's Sync step 2a.

## Summary

All three blocking findings from round 1 are fixed:
- **spec R-TRI-2** (docs/spec.md:203) now says that `--tier` skips triage and that `ns-conductor risk-check` records the floor at Sync.
- **triage-rubric skill**: the SKILL.md now says that triage does not run with `--tier`, and points to `risk-check`.
- **cache-hit test**: the new test in tests/bats/conductor-loop.bats proves that a cache hit writes one `== cached` line and no second `== run` line. It passes.

The non-blocking findings from round 1 are fixed too:
- The event string now checks `[ "$tags" = "[]" ]`.
- The exact ntfy call is in the run skill.
- Step 3 now says "the checks output".
- `risk_floor` is listed in the run-ledger skill.

The rest of the diff still matches the mini-plan:
- The waiting and busy-worktree rules are in run, implement and implementer.
- Triage is skipped for an owner tier.
- `ns-conductor risk-check` is documented and tested, and it never changes `tier` or `tier_source`.
- The report has a `Full suite runs` row (cache hits not counted, flagged for a T0/T1 run with more than one).
- The schema, ledger.md, usage.md and the CHANGELOG are updated.

I found no untrusted text copied into the code and no `.nightshift/` files on the branch. Neither finding blocks.

REVIEW verdict=approve head=357f1fb79b6489263acffa7fa67a1abd733d576e

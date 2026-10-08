## Summary
Fixes #175 (#169 part 2): new review verdict `approve-after-nits` for the T0/T1 flow. `ns-conductor review-round` accepts it only with a matching verdict line, a head that is the branch head or an ancestor, and no blocking finding (exit 9 otherwise). `merge` accepts either approving verdict at the current head. The T1 flow now runs the full suite once on the final head instead of before each review round. Skills, agents, docs, schema, CHANGELOG and bats tests updated.

## Checks
| Check | Result |
|---|---|
| python lint | PASS |
| python test (bats) | PASS |

No SKIP rows. Details in the run's dod.md.

## Non-blocking findings and open items
- docs/conductor.md:190: the `Full suite runs` = 1 claim has no test.
- bin/lib/conductor-loop.sh:673: the blocking-finding grep matches only the exact `- blocking · ` form.
- bin/lib/conductor-loop.sh:612: `approve-after-nits` is accepted for any phase and tier; only the prompts restrict it to T0/T1 `fix`.
- plugins/ns/agents/code-reviewer.md:30: still says approval needs the current head (ancestor is accepted for nits).
- plugins/ns/skills/budget-guard/SKILL.md:12: does not list `approve-after-nits`.
- plugins/ns/skills/run/SKILL.md:44: T0 Sync wording on risk-check.

## Follow-ups
- kill.bats test 9 (ns_kill_group give-up, <=5 s wall) failed once in the full suite under load; passes alone. Unrelated to this diff.
- Stack-base conflict before review; the integrator resolved it.

## Stack
Stacked on fix/ns-166 (the ns-166 PR). The merge of fix/ns-166 into fix/ns-175 (b581f45) merged cleanly in the integrate step; no conflicts remained.

## Run report
RUN/run-report.md on the plan branch plan/ns-175.

## Desk link
See `ns status ns-175`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

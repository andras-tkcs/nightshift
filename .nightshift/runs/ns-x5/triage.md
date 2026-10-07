tier: T2
size_tier: T2
risk_floor: none
tags: [bash, bats, skills, conductor]
budget_hours: 8
summary: Cut repeated full bats runs per run via touched-tests-only guidance, a locked and cached `ns-conductor checks`, a wrong-target warning and a later stack-base merge

## Reasons
- Size: five changes across `bin/ns-conductor` (lock, cache keyed by tree SHA and target, `--force`, target warning) and several skills (implement, run/integrate, implementer agent). Needs new bats tests (lock, cache hit and miss, wrong-target warning), skill doc updates and a CHANGELOG entry. This is new CLI surface (`--force`) and a behaviour change across modules, which fits T2 and not T1.
- Unknown: item 4 needs research into why the conductor picked the `feature` target in ns-x4. The request already allows a skill fix or a warning, so the scope is bounded.
- Risk: no path matches a profile risk zone (`plugins/ns/hooks/**`, `bin/lib/config.sh`, `bin/ns-launch`). The profile has no `platform_paths`, so no platform floor applies. I found no invariant at stake and no new trust boundary, so the floor is none.
- Not lower than T2 because of the cross-module scope and docs. Not T3 because there is no trust boundary or ADR need.
- The profile has no `budgets` section, so `budget_hours` is the rubric default for T2 (8).
- The python stack paths (`bin/lib/*.py`, `tests/docs-check`) are probably not touched, so I did not add a python tag.
- The change is concurrency-sensitive (lock) and affects the check gate, so review should look at stale-lock handling and cache invalidation. Cached results must never let a red or stale tree pass.
- Used 2 tool calls (profile, rubric) before writing this file. I did not survey the code, so file counts are estimates.

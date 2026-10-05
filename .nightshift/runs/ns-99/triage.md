tier: T2
size_tier: T2
risk_floor: none
tags: [python, bash, ci, tests, "protected:.github/workflows"]
budget_hours: 8
summary: Speed up the bats suite by lazy-importing jsonschema, cutting Python launches, running bats in parallel and sharding CI

## Reasons

- Size: touches several modules (bin/lib/nsyaml.py, bin/lib/profile.py, bin/lib/*.sh, tests/bats helpers, .github/workflows/ci.yml) and needs docs updates. Baseline timings must be recorded, and the work probably splits into 2 to 3 phases (Python launch reduction, then CI restructure).
- Unknowns: how many Python launches per test can be removed without weakening tests, and whether fixture state can be shared safely. lazy-import.bats and parallel.bats already exist, so some of this may be partly done.
- Risk zones: no match. No changes to plugins/ns/hooks/**, bin/lib/config.sh or bin/ns-launch are expected, so the floor is none. Re-check if the Python launch cuts reach config.sh.
- Protected path: .github/workflows/** is listed under protected_paths. Edits to ci.yml need the owner's approval and cannot be self-merged. The profile has no platform_paths, and no new trust boundary or invariant is at stake.
- Why not lower: it spans code, tests, CI and docs, with a no-weakened-tests constraint and several acceptance criteria. It is not a one-file fix.
- Budget: the profile has no budgets section, so the default T2 value of 8 hours is used.

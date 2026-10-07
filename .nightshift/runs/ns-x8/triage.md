tier: T2
size_tier: T2
risk_floor: none
tags: [bash, bats, tests, perf]
budget_hours: 8
summary: Speed up the 835-test bats suite (target under 5 min at --jobs 8) with stubs, fake clocks and setup_file, remove host-state dependence, and check parallel safety
---
## Reasons

- Size: the change cuts across many files in tests/bats and shared helpers, so it is a multi-module change. It needs a profiling pass (`bats --timing`), a per-test root-cause analysis and a parallel-safety audit, and the PR body needs before/after timings. That is more than a small T1 fix, so it fits T2 with 1 to 3 phases.
- Unknowns: the slow tests are not known until they are measured. A full run takes about 15 minutes, which makes iteration costly.
- Risk: the intended edits are under tests/bats and the test helpers. No profile risk_zones path matches (plugins/ns/hooks/**, bin/lib/config.sh, bin/ns-launch). No platform_paths match. Floor is none. If a fix needs a change to one of those paths (for example a clock or tmux seam in bin/ns-launch or config.sh), re-triage with floor T1 and the sec-compliance tag.
- No invariant or trust boundary is at stake as long as no assertions are removed or weakened (see ns:test-strategy).
- The owner set T1. Triage recommends T2 (R-TRI-2), and the owner's override stands. The budget here is the T2 default of 8 hours because the profile has no budgets section. A T1 run would get 2 hours, which is likely too tight given 15-minute suite runs. Only 2 bats runs may happen at the same time (CLAUDE.md).
- Neither stack-specific specialists nor a UI or database tag applies.

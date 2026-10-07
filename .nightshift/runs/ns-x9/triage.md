tier: T1
size_tier: T1
risk_floor: none
tags: [bash, bats]
budget_hours: 2
summary: Change printf format strings that start with "--" to printf -- '...' in bin/lib/ns-*.sh
---
## Reasons

- Size: mechanical one-token fix in 3 files (bin/lib/ns-ls.sh, ns-status.sh, ns-gc.sh), found by grep for `printf '--` or `printf "--`. No behavior or interface change.
- Risk: none of the files match a risk zone (hooks `plugins/ns/hooks/**`, credentials `bin/lib/config.sh` and `bin/ns-launch`). No platform paths, invariants or trust boundaries are involved. The `.github/workflows/**` protected paths are not touched.
- Why not T0: it touches several shipped tools, so it needs a bats regression test (a tool that prints a `--` line must not emit a printf error) and a lint run.
- Suggested checks: `tests/lint` and the bats suite. Also grep for other `printf` calls with a format beginning with `-`, including variable formats and `echo`.
- The profile has no `budgets` section, so budget_hours is an assumed default of 2 for T1.

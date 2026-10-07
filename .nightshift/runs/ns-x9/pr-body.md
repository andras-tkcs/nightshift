## Summary
Fix `printf` calls in ns tools that fail with `printf: --: invalid option` when the format starts with `--`: `bin/lib/ns-ls.sh`, `ns-status.sh` and `ns-gc.sh` help lines now use `printf -- '...'`. Adds `tests/bats/printf-dashes.bats` (help commands plus a lint test that greps bin/ for formats starting with a dash). Review round 1: approve.

## Checks
| Check | Result |
|---|---|
| tests/lint | PASS |
| bats tests/bats | PASS |

No SKIP rows.

## Non-blocking findings and open items
- The lint test regex `printf +(['"])-` only catches literal quoted formats; variable formats and unquoted `printf -x` are not covered. Nothing in bin/ is affected today.

## Follow-ups
- bootstrap.bats test 32 (step 1 with a failing apt-get) fails on main too in some environments, unrelated to this change (passed in this run's final checks).

## Stack
Base: main (no other open run PR). The branch also contains merges of earlier stacked runs already on main.

## Run report
`.nightshift/runs/ns-x9/run-report.md` on branch plan/ns-x9; `ns-conductor finish` publishes it.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

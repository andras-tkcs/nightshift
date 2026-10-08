tier: T2
size_tier: T2
risk_floor: none
tags: [bash, python, docs]
budget_hours: 8
summary: Conductor overhead (#169 part 1): wait instead of polling, hands off busy worktree, --tier skips triage, count full-suite runs in report, with a new Sync diff-matching script

## Reasons
- Size: about 8 or more files across modules: 3 plugin prompts (run and implement skills, implementer agent), docs/conductor.md, a new bin/ script, the report renderer (ns-report.sh / report.jq), bats tests and CHANGELOG.
- New public surface: a new bin/ command and a new `--tier` skip-triage behaviour, plus a new report row ("Full suite runs").
- Four loosely related behaviour changes in one issue, spanning conductor prompts and tooling; docs must change with them.
- Risk floor none: no listed path touched (plugins/ns/hooks/**, bin/lib/config.sh, bin/ns-launch). The new script only reads risk_zones/platform_paths; it should be reviewed so it does not weaken the floor rule, but it does not itself change a risk zone. No platform_paths declared in the profile, no trust boundary.
- Why not T1 (owner suggestion): the change touches many modules and adds new surface, which is T2 by the rubric. The owner can still override with `--tier`.
- Profile has no budgets section, so the rubric default of 8 hours for T2 applies.

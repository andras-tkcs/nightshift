# Mini-plan ns-174 (issue #174, conductor overhead, part 1 of #169)

Not a bug: a feature-sized T1 (owner tier). Tests first where a script/report is involved.

## Changes
1. Waiting rule (plugins/ns/skills/run/SKILL.md Start step 4, implement/SKILL.md, agents/implementer.md):
   wait for a subagent via the Agent call's return or its task notification, for workers via
   `ns-conductor wait`; never write fetch/sleep/file-poll loops (no skill text may describe one).
2. Busy worktree: while an implementer works in a worktree the conductor runs no tests/checks/edits there;
   `ns-conductor checks` only after the implementer returned. Same text in run, implement, implementer.
3. Skip triage when tier_source=owner (run SKILL.md Triage). New script `bin/ns-risk-check <id>` (or an
   `ns-conductor risk-check` subcommand, implementer's choice, documented): at Sync matches the run's diff
   (origin/<base>...feature/fix branch) against profile risk_zones and platform_paths, records tags
   (`sec-compliance`, `platform:<p>`) and `risk_floor` in the ledger; only when floor > owner tier set
   `tier_recommended` and name it in the ntfy line. Triage still runs when no tier given.
4. Report: Summary row `Full suite runs` = count of `ns-conductor checks` runs of the full test target,
   cache hits excluded (from logs/<id>/*.checks log, bin/lib/report.jq / report_logs.py). T0/T1 with >1 is
   flagged in the Summary.
5. docs/conductor.md (triage skip + Sync risk check), docs/usage or ledger docs if fields change,
   CHANGELOG `[Unreleased]` entry.

## Tests (bats, tests/bats; follow suite-speed rules, ns_cached_fixture)
- risk check: no tier_recommended when owner tier >= floor; tier_recommended recorded when floor above.
- report: `Full suite runs` with one cache hit (not counted) and two real runs; T1 with two flagged.
- skill text check: no `sleep`/fetch loop in run, implement, implementer.

Run only covering bats files + tests/lint + tests/docs-check; full suite via `ns-conductor checks`.

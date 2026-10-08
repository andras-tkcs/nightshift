# Review fix round 1: ns-174

Range: `origin/main...origin/fix/ns-174`, head 20741f997a643ed931e5015529fe845f07e69ca5. Judged against `RUN/mini-plan.md`, CLAUDE.md and docs/conductor.md. No worker log was offered. I did not run the checks because the caller did not ask for them.

## Findings

- blocking · docs/spec.md:203 · R-TRI-2 still says "Triage records the override and its own recommendation". With an owner tier, run/SKILL.md:27 now says never to launch `ns:triage`, so the requirement and the skill contradict each other. Spec §15 says every phase updates the docs it affects. · Reword R-TRI-2: with `--tier`, triage is skipped and `ns-conductor risk-check` records the risk floor at Sync, setting `tier_recommended` only when the floor is above the owner's tier.
- blocking · plugins/ns/skills/triage-rubric/SKILL.md:50 · "The owner can always override with `--tier`; triage still records its own recommendation (R-TRI-2)" is now false: triage no longer runs for an owner tier. · Change it to say that triage does not run with `--tier`, and point to `ns-conductor risk-check` for the floor rules (risk_zones and CI platform_paths give T1).
- blocking · bin/lib/conductor-loop.sh:399 · New behaviour has no test: a cache hit now appends `== cached <UTC>` to the checks log (docs/conductor.md used to say "leaving the log alone"). The report tests in report.bats build the logs by hand, so nothing proves that `ns-conductor checks` writes this line, or that it writes no `== run` line on a hit. The `Full suite runs` count depends on both. · Add a test to tests/bats/conductor-loop.bats next to the ns-x6 test: run `checks feature` twice on a clean tree (no `--force`), then assert one `^== run ` line and one `^== cached ` line in `feature.checks.log`.
- non-blocking · bin/lib/conductor-loop.sh:489 · `${tags:+...}` is always taken because `$tags` is at least `[]`, so a run with no match logs the event `risk_floor T0 tags ` with an empty list. · Test `[ "$tags" != "[]" ]` instead.
- non-blocking · plugins/ns/skills/run/SKILL.md:90 · "name it in the run's ntfy line (`ns-notify`)": the run skill has no other ntfy line, so it is unclear which message is meant, or whether the conductor sends its own. · Give the exact call, for example `ns-notify "ns: <id> risk floor T1 is above owner tier <T>"`.
- non-blocking · plugins/ns/skills/run/SKILL.md:90-91 · Step 2a sits between the checks call (2) and step 3, whose "its output" means the checks output. With 2a in between, "its" now reads as the risk-check output. · Move the risk check to its own step after step 4, or say "the checks output" in step 3.
- non-blocking · plugins/ns/skills/run-ledger/SKILL.md:15 · The ledger field list does not have the new `risk_floor`. · Add `risk_floor` (optional, T0 or T1, set by `ns-conductor risk-check`).

## Summary

The change matches the mini-plan:
- The waiting rule and the busy-worktree rule have the same text in run, implement and implementer.
- Triage is skipped when the owner gave the tier.
- `ns-conductor risk-check` is a subcommand, documented in docs/conductor.md. It has a correct glob matcher, only CI platforms count, it never touches `tier` or `tier_source`, and it sets `tier_recommended` only when the floor is above the owner's tier.
- The report has a `Full suite runs` row with the T0/T1 flag.
- The ledger schema, ledger.md, usage.md and the CHANGELOG are updated.

The tests were committed first (263dc0e), and the fix commit did not change any bats file. The only test file it changed is the report fixture, which gains the new row.

Three findings block approval:
- spec R-TRI-2 contradicts the new triage skip;
- the triage-rubric skill contradicts it too;
- nothing tests that a checks cache hit writes the `== cached` line the report relies on.

I found no untrusted text copied into the code and no `.nightshift/` files on the branch.

REVIEW verdict=changes head=20741f997a643ed931e5015529fe845f07e69ca5

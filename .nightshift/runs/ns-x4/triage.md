tier: T2
size_tier: T2
risk_floor: T1
tags: [bash, python, "risk:credentials", sec-compliance]
budget_hours: 8
summary: Rename the ns health-check subcommand to ns check across bin, docs, skills, tests, schema and systemd unit
---

## Reasons

- Size: about 20 files across bin/, bin/lib/, docs (6 files), plugins/ns/skills (3), tests/bats, schema/ledger.schema.json, templates/systemd and CHANGELOG. This is a public CLI rename, so it needs docs, tests and compatibility decisions (alias for the old name, systemd unit ns-health.service, schema field names). That is T2 (change across modules with public surface and docs), not T1.
- Risk: bin/ns-launch matches the `credentials` risk zone, so the floor is T1, with tag sec-compliance and tag risk:credentials. No hooks path is in the survey. Re-check plugins/ns/hooks/** for health-check references.
- Tier: max(T2, T1) = T2.
- Owner override: the owner set T1. Triage records its own recommendation of T2 (R-TRI-2). If the owner keeps T1, scope should be limited to a mechanical rename plus a deprecated `health-check` alias, and the schema and systemd unit renames should be deferred.
- Budget: the profile has no `budgets` section, so the default for T2 (8 hours) applies.
- No specialists are listed in the profile, so none are tagged.

tier: T2
size_tier: T2
risk_floor: T1
tags: [bash, python, "risk:hooks", sec-compliance]
budget_hours: 8
summary: Add owner-only 'ns note <id> "text"' that appends timestamped owner_notes to the ledger, read by the conductor at stop_requested checkpoints and reported
---
## Reasons

- Size signals: new public CLI command, new ledger field and event (schema/ledger.schema.json, bin/lib/ledger.sh, bin/ns-ledger), conductor behaviour change (plugins/ns/skills/run/SKILL.md), report change (bin/lib/report.jq), and four docs (usage, ledger, conductor, plus guard docs) plus bats tests. This is a feature across several modules, so T2. It is modelled on the existing ns-stop.sh and stop_requested, so there is little research.
- Risk: the change edits plugins/ns/hooks/lib/guard.py, which matches the `hooks` risk zone (plugins/ns/hooks/**). That gives floor T1, tag sec-compliance and tag risk:hooks. No platform_paths are declared in the profile.
- Owner-only authority and notes that "override the plan's scope" are a trust-sensitive input path to the conductor. This needs careful review, but it is the same owner channel as stop_requested and not a new network boundary, so I did not raise it to T3.
- Why not lower: new public surface, schema change and a guard change exceed T1.
- The profile has no `budgets` section, so budget_hours uses the rubric default for T2 (8).
- Tool calls used: 2.

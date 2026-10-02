---
name: triage-rubric
description: Size signals, risk signals, tier definitions T0-T3 and the floor rules used to pick a run's tier; load when triaging a request.
user-invocable: false
---

# Triage rubric

The tier is `max(size_tier, risk_floor)` (R-TRI-1). Score size and risk separately, then combine.

## Size signals (generic)

- Estimated files and modules touched.
- New public surface: a tool, setting, CLI flag or UI page.
- Unknowns that need research.
- Cross-platform or packaging impact.
- Docs that must change with the change.

## Size tiers

| Tier | Meaning | Example |
|---|---|---|
| T0 | One file, obvious fix, no new behaviour | Fix a typo in an error message |
| T1 | A bug or small change in a few files, a reproducing test is possible | A function returns the wrong value for an empty list |
| T2 | A feature or change across modules, new public surface or docs; 1 to 3 phases | Add a CLI flag with settings, tests and docs |
| T3 | Large or unknown scope, needs research and an ADR, or opens a new trust boundary | Let the app accept input from a new network client |

## Risk signals (from the profile)

- A changed path matches a declared risk zone.
- Changes an approval, policy or PII decision.
- Touches credentials, auth or the audit trail.
- Alters what data reaches the AI client.
- Changes a compliance claim in docs or website.
- Runs SQL, changes a schema or releases query results: tag `database-expert`.
- Defines metrics, datasets or reports: tag `data-analyst`.
- Changes a screen, dialog, settings page or the website: tag `ui-ux-designer`.
- Touches macOS- or Windows-only code: at least T1, plus that platform's CI dispatch.

Only tag specialists the profile lists under `specialists`.

## Floor rules

- No risk signal: floor `none`.
- Any `risk_zones` path match: floor T1, tag `sec-compliance`, plus tag `risk:<zone>`.
- A `platform_paths` match for a platform with `verify: ci`: floor T1, tag `platform:<p>`.
- An invariant of the project is at stake: floor T2.
- A new trust boundary: floor T3.

The owner can always override with `--tier`; triage still records its own recommendation (R-TRI-2).

## Budgets

`budget_hours` is the profile's `budgets.<tier>.hours`. Defaults when the profile is silent: T0 0.5, T1 2, T2 8, T3 36 hours. Review rounds default to 1, 3, 3, 3.

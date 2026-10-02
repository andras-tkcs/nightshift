---
name: plan-manifest
description: The exact format of a plan's Implementation manifest (fields, validation rules, example) that /ns:implement parses; load when writing or checking a plan.
user-invocable: false
---

# Plan manifest

The plan document ends with one fenced `yaml` block under the heading "Implementation manifest". `/ns:implement` parses that block and nothing else, so it is exact. Unknown keys are ignored; missing required keys fail validation.

## Fields

Top level:

| Key | Required | Meaning |
|---|---|---|
| `plan_slug` | yes | the run's slug |
| `feature_branch` | yes | `feature/<slug>` (or the project's `<type>/<kebab-case>` convention) |
| `max_parallel` | no, default 2 | phases started at once; never above 2 on this machine |
| `manual_steps_source` | no | repo path of a committed copy of the manual steps; omit when there are none |
| `manual_before` | no | list of `{id, title, why, done_when}`; the owner does these before any phase starts |
| `manual_after` | no | list of `{id, title, why}`; the owner does these after the last merge; they go into the PR body as unchecked boxes |
| `verify_after_merge` | no | commands the conductor runs after each phase merge |
| `final_checks` | no | statements checked before the PR opens (plan file deleted, ADRs exist, changelog entry) |
| `phases` | yes | list of phases, below |

Each phase:

| Key | Required | Meaning |
|---|---|---|
| `id` | yes | `p<n>-<kebab>`, unique |
| `title` | yes | one line |
| `depends_on` | yes | list of phase ids, `[]` for none |
| `complexity` | yes | `S` (up to about 3 source files, 150 lines) or `M` (up to about 8 files, 400 lines) |
| `touches` | yes | every file or glob the phase may change; the only paths its worker may commit |
| `brief` | yes | numbered, prescriptive steps with no open decisions |
| `acceptance` | yes | list; each item a named test, a grep or a command with its expected output |
| `model` | no | `opus` for a phase that cannot be made mechanical; then `model_reason` is required |
| `human_gate` | no | `true` makes the conductor open gate 1.5 after the phase merges, with the question "approve phase <id>?" |

## Validation rules

1. Phase ids are unique and every `depends_on` id names a phase in the list.
2. The dependency graph has no cycle.
3. Two phases that can run at the same time (neither reaches the other through `depends_on`) have disjoint `touches`: no shared path, and no glob that covers the other's path.
4. `complexity` is `S` or `M`. There is no `L`: split the phase.
5. Every phase has a non-empty `brief`, `acceptance` and `touches`.
6. A phase with `model` set has `model_reason`; `max_parallel` is 1 or 2.
7. The last phase depends on every other phase and is the retirement phase (ADRs, reference docs, deletes the plan document, changelog entry).
8. `manual_before` and `manual_after` ids are unique and start with `mb` and `ma`.

Check these yourself before handing the plan over; the plan skill's review step lists the same rules.

## Example

```yaml
plan_slug: deny-feedback
feature_branch: feature/deny-feedback
max_parallel: 2
manual_before: []
manual_after:
  - {id: ma1-real-client, title: Try a denial in a real client, why: CI cannot drive the client UI}
verify_after_merge: ["python3 -m pytest tests/unit -q"]
final_checks: ["docs/deny-feedback-plan.md is deleted", "CHANGELOG.md has an [Unreleased] entry"]
phases:
  - {id: p1-core, title: Add the denial reason field, depends_on: [], complexity: S, touches: [src/policy.py, tests/unit/test_policy.py], brief: "1. Add reason to Denial in src/policy.py. 2. Extend tests/unit/test_policy.py.", acceptance: ["python3 -m pytest tests/unit/test_policy.py -q passes"]}
  - {id: p2-docs, title: Retire the plan and write docs, depends_on: [p1-core], complexity: S, touches: [docs/**, CHANGELOG.md], brief: "1. Document the field. 2. Delete the plan document.", acceptance: ["test ! -e docs/deny-feedback-plan.md"]}
```

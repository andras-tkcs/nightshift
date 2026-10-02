# Build plan

Input for `/make-plan`. It turns this into `docs/build-a-plan.md` with an implementation manifest that `/implement-local` executes. Requirements are in `docs/spec.md` and referenced by ID.

## Constraints for both builds

- Runs on ns-main as user `ns`: no sudo, 4 GB RAM, 2 workers at most at once.
- Phases must fit the seed planner's sizing rules: S (≤3 files, ≤150 lines) or M (≤8 files, ≤400 lines). Phases in the same wave have disjoint `touches`.
- No phase may touch the `privacyfence` repo. End-to-end tests use `nightshift-sandbox` only.
- Every phase ends with its docs: a phase that adds a command or profile key updates `docs/usage.md` or the schema in the same phase.
- No manual steps in the middle. Anything that needs the owner goes to `manual_after`. Real installation as root is Review 1, not part of Build A.

## Build A: the whole core

Workstreams in dependency order. The planner cuts them into phases and waves.

| # | Workstream | Delivers | Spec | Depends on |
|---|---|---|---|---|
| A1 | Scaffold | Repo layout, marketplace + `ns` and `ns-python` plugin manifests, `README.md` skeleton, CI workflow (shellcheck, bats, plugin validate), `CHANGELOG.md` | §3, R-TST-1 | — |
| A2 | Profile | `schema/profile.schema.json`, `ns profile check`, generator for `docs/profile-reference.md`, schema tests, example profiles (sandbox, a draft for PrivacyFence in `templates/`), and **Nightshift's own** `.claude/project-profile.yaml` and `.claude/ns-github.env`, so registering this repo in phase 5 needs no onboarding run | §4 | A1 |
| A3 | CLI core | `bin/ns` dispatcher, config/registry/token handling, `project add` (adopts an existing clone, R-CLI-4), `new`, `ls`, `attach`, `status`, `stop`, `help`; the onboarding run (R-ONB); bats tests | §5, R-CLI-*, R-ONB | A1 |
| A4 | Desk and notify | `ns publish`, `ns approve` (diff + commit + `--yes` for sandbox only), `index.md`, `ns-notify` | §10 | A3 |
| A5 | Ledger | Ledger format, read/write library, checkpoint hook, resume algorithm, tests incl. corrupted/partial ledger | §8, R-HK-2 | A3 |
| A6 | Guard and session hooks | `guard` and `session-start` hooks with tests | R-HK-1, R-HK-3, R-SEC-* | A2 |
| A7 | Triage and T0/T1 | triage agent, triage-rubric skill, implementer and code-reviewer agents, review-checklist skill, `/ns:run` for T0/T1, `ns-python` stack (`stack.yaml`, three skills) | §6, §7 | A2, A3, A5 |
| A8 | Planning and gates | Port the seed `make-plan` into `/ns:plan` (profile keys replace PrivacyFence facts), product-analyst, architect, test-architect, planner agents, gate 1 via the desk | §6, §7 | A4, A7 |
| A9 | Conductor | `bin/ns-conductor`: workers as headless `claude -p`, worker pool, budgets, review-loop cap, escalation (gate 1.5), auto-mode check | §9, R-BUD-* | A5, A7 |
| A10 | T2/T3 execution | `/ns:implement` (ported from the seed orchestrator onto the conductor), integrator agent, `/ns:dod` (ported), ci-dispatch skill (ported from steward), researcher and sec-compliance agents, HTML handoff report template | §6, §9, R-CON-5/6 | A8, A9 |
| A11 | Operations | `ns drain`, `up`, `resume`, `gc` (with `--dry-run`), `doctor`, systemd user unit and timer files | §5, §12 | A9 |
| A12 | GitHub settings | `bin/ns-gh` from the draft, gh stub, tests | §13 | A1 |
| A13 | Bootstrap | `bin/bootstrap.sh` with `--check` and `--upgrade <tag>`, release install under `/opt/nightshift/<tag>`, tests of `--check`, Caddyfile and unit templates | §14, R-BS-* | A4, A11 |
| A14 | E2E harness | `tests/e2e/` runner, `tests/fixtures/sandbox-base/`, scenarios R-E2E-1…5, cleanup | §16 | A10, A11 |
| A15 | Documentation | All files of §15 except `docs/stacks.md`, `docs-check` test, `README.md` final, `docs/architecture.md` from the architecture page | §15 | all; may run alongside A12–A14 |
| A16 | Release | Tag `v0.1.0`, CHANGELOG entry, `manual_after` checklist = phase 4 of the architecture page | R-LAY-3 | A14, A15 |

**Build A is done when:**
1. CI is green on the PR (R-TST-1).
2. All five end-to-end scenarios passed on ns-main, and their PRs exist on `nightshift-sandbox`. The final report links them.
3. `docs-check` passes, and `docs/setup.md` describes every step `bootstrap.sh` performs.
4. One PR to `main` of `nightshift`, with `manual_after` listing what the owner does at Review 1.

## Review 1 (owner)

Phase 4 of the architecture page: run `bootstrap.sh`, `ns-gh`, add PrivacyFence, run one real T1 and one real T2 on PrivacyFence, then write `docs/review-1.md` on the desk.

## Build B: fixes and breadth

Run by Nightshift itself: `ns new ns-buildb --tier T3 "Build B from docs/build-plan.md and docs/review-1.md"`.

| # | Workstream | Delivers |
|---|---|---|
| B1 | Review fixes | Everything in `docs/review-1.md`, first and in its own phases |
| B2 | Specialists | database-expert, data-analyst, ui-ux-designer agents; data-modeling, query-review, data-quality, ui-review, mockups skills; triage tags |
| B3 | Stacks | `ns-node`, `ns-web`, `ns-shell`, `ns-powershell` plugins; platform dispatch tested on a sandbox branch with a macOS-only path |
| B4 | Onboarding | `/ns:init` (starter files from `templates/`), `/ns:onboard` (research a repo, draft profile, `CLAUDE.md` and first domain skill on the desk) |
| B5 | Lab | Lab helper on hcloud: create, run, delete; gc of servers and snapshots |
| B6 | PrivacyFence PRs | Two PRs, not merged by Nightshift: (1) `live-qa` environment on the QA workflows, prepared as a patch for the owner because the token has no Workflows permission, plus a checklist item to confirm the existing `release` environment has the owner as required reviewer, since the agent token can dispatch workflows; (2) remove `/make-plan`, `/implement`, `/dod`, steward; trim `CLAUDE.md`; add the profile and `pf-*` skills |
| B6a | Usage monitoring | Spec §16a: usage in the ledger from workers and sessions, `ns usage`, `--max-budget-usd` caps per phase, usage section in the handoff report, daily ntfy line and alert, weekly `usage.html` on the desk |
| B7 | Docs | `docs/stacks.md`; agents, projects and usage docs updated, including `ns usage` |
| B8 | Release | `v0.2.0` |

## Review 2 (owner)

Install `v0.2.0`, run a real T3 on PrivacyFence, onboard a second repo with `/ns:onboard`, merge the two PrivacyFence PRs.

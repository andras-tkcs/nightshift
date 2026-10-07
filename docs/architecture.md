# Architecture

What Nightshift is and how its pieces fit. For the commands see [usage.md](usage.md); for the requirements see [spec.md](spec.md). Items marked "Build B" are designed but not built yet.

Nightshift is a personal agent pipeline that runs while you are at your day job. Everything runs on one Ubuntu server with the Claude Code CLI. You reach it from an iPad or a browser tab over a private network, steer at the start and the end, and the server does the long middle. One generic plugin does the work, and each project's own repo tells it what matters there.

## Where things run

You never run anything on the iPad or the work laptop. They are terminals into the server over Tailscale, so the server has no ports open to the internet. GitHub holds the queue, the branches and the run ledger, so a run survives a server reboot.

- Your windows: the iPad (Blink Shell over mosh) and a work browser tab (the review desk behind Cloudflare Access). Nothing runs on them.
- `ns-main` (Ubuntu 24.04, user `ns`, no sudo): the Claude Code CLI signed in with your subscription, the Nightshift plugins, one tmux session per run, one git worktree per run and per phase.
- GitHub: the repository, issues, the branches, branch protection on `main` and Actions for platform checks.
- Phone: ntfy pushes at gates, with a link to the document.
- `ns-lab` (a throwaway server per test): Build B.

Tailscale is the private network for you and the servers. Cloudflare Tunnel is only the browser door from a laptop without Tailscale.

### How a run executes

- **Headless conductor sessions (ADR 0003, ADR 0008).** A run's conductor is a headless `claude -p "/ns:run <id>"` session that `ns-launch` starts inside a detached tmux session named after the run. `ns attach <id>` shows it. A gate ends the session (state `waiting`); `ns approve` starts a new one. See [conductor.md](conductor.md).
- **Detached workers (ADR 0008).** The conductor starts one headless worker per phase with `setsid`, each in its own worktree. Workers survive a conductor crash, and a resumed conductor adopts them again through their pid files. A global pool limits how many run at once.
- **The ledger on `plan/<id>` (ADR 0002).** Every run has a ledger file, `.nightshift/runs/<id>/ledger.yaml`, committed on the branch `plan/<id>` for every tier. Code lives on separate branches (`fix/<id>` for T0 and T1, the feature branch for T2 and T3), so the ledger never reaches the project's pull request. Every step is checkpointed, so a reboot resumes instead of restarting. See [ledger.md](ledger.md).

## What gets installed

The generic layer ships as Claude Code plugins from the Nightshift repo, which is a plugin marketplace. They are installed once at user scope on `ns-main`, so every project gets them. The project layer lives in each project's own repo.

| Layer | What | Where |
|---|---|---|
| Plugin `ns` | Agents, skills, the `/ns:` commands and hooks (a guard for protected paths, a budget check on every tool call, a checkpoint on stop) | `plugins/ns/` |
| Plugin `ns-python` | Python stack skills and `stack.yaml` | `plugins/ns-python/` |
| Server kit | `ns`, `ns-conductor`, `ns-ledger`, `ns-launch`, `ns-notify`, `ns-gh`, `bootstrap.sh` | `bin/`, installed under `/opt/nightshift` |
| Project pack | `.claude/project-profile.yaml`, domain skills, a short `CLAUDE.md` | the project's repo (see [projects.md](projects.md)) |

`project-profile.yaml` is the only contract between the layers. Generic agents never hard-code project facts; they read commands, protected paths, risk zones, compliance regimes and domain skills from the profile. See [profile-reference.md](profile-reference.md). The agents and skills are described in [agents.md](agents.md).

The bash tooling handles YAML through one Python helper, `bin/lib/nsyaml.py`, plus `jq` (ADR 0004). Its subcommands are `to-json`, `from-json`, `validate` and `read` (validate and print as JSON in one launch, used for ledger reads).

The specialist bench (database expert, data analyst, UI/UX designer) is Build B, together with the skills they use.

## Languages and platforms

The core (agents, tiers, triage, ledger, review desk) knows no language. Each language is a stack plugin, and a project lists every stack it uses with the paths it covers. Separately it lists the platforms it ships to, because some code can only be built and tested on its own operating system.

| Stack plugin | Checks | State |
|---|---|---|
| `ns-python` | pytest, ruff, mypy, pip-audit, a venv per worktree | Built (Build A) |
| `ns-node`, `ns-web`, `ns-shell`, `ns-powershell` | npm, HTML validation, shellcheck and bats, PSScriptAnalyzer | Build B |
| `ns-swift` | swift test, xcodebuild | Later |

How runs use stacks: skills load by path, each touched stack's lint and tests run in its own paths, and a platform whose `verify` is `ci` is proven by dispatching that platform's GitHub workflow (the `ci-dispatch` skill). Touching such code raises the risk floor to at least T1. Adding a stack later changes nothing in the core.

## Tiers

Triage picks the smallest tier that is safe, and risk can push a small change up a tier.

| Tier | For | Where it runs | Gates |
|---|---|---|---|
| T0 Patch | Typo, docs wording, config value | One conductor session, one implementer | PR merge |
| T1 Fix | One bug-fix issue: mini-plan, failing test first, one reviewer | One conductor session | PR merge |
| T2 Feature | A change inside one area, 1 to 3 phases | Detached workers | Plan (gate 1), final (gate 2) |
| T3 Epic | New surface or trust boundary: research, ADR, security pre-review, parallel phases, review board | Detached, parallel workers | Plan, escalation if needed, final |

| Agent | T0 | T1 | T2 | T3 |
|---|---|---|---|---|
| triage | yes | yes | yes | yes |
| conductor | yes | yes | yes | yes |
| researcher | | | | yes |
| product-analyst | | | lite | full |
| architect | | | lite design | design plus ADR |
| planner | | | yes | yes |
| test-architect | | | yes | yes |
| implementer | one | two steps | one per phase | one per phase, parallel |
| code-reviewer | | one | per phase and whole | per phase and whole |
| sec-compliance | | | when tagged | pre and post |
| integrator | yes | yes | yes | yes |
| specialists | | | Build B | Build B |

## How triage decides

Size and risk are scored separately; `tier = max(size_tier, risk_floor)`.

- Size signals: files and modules touched, new public surface, unknowns that need research, platform or packaging impact, docs that must change.
- Risk signals come from the profile: a path in a declared risk zone, a change to an approval, policy or PII decision, credentials or the audit trail.
- Risk floor: none gives T0; any risk zone gives T1 plus the `sec-compliance` tag; an invariant at stake gives T2; a new trust boundary gives T3.
- You can always override: `ns new <id> --tier T1`.

The rubric is the `triage-rubric` skill; the agent is `triage` (see [agents.md](agents.md)).

## A T3 run, start to finish

Your time goes to the evening before and the evening after. Everything between runs detached and checkpoints after each phase.

1. **Intake.** `ns new app-123` creates the worktree and branch `plan/app-123`, writes the ledger and starts the conductor. Triage proposes a tier and a budget; you confirm.
2. **Discovery.** Researcher, product-analyst, architect (ADR), planner, test-architect and a security pre-review write into `plan/<id>`.
3. **Gate 1: plan review.** You get a push with a link. Plan, ADR and acceptance tests are on the review desk; edit the Markdown, then `ns approve app-123`.
4. **Build loop.** Per phase: implement, tests, review, at most three rounds, then merge into the feature branch. Independent phases run in parallel workers.
5. **Gate 1.5: escalation, only if needed.** A stuck or over-budget phase writes `escalation.md`; you answer on the desk and run `ns approve`.
6. **Verify.** The review board: code-reviewer on the whole branch, sec-compliance post-review, product-analyst against the acceptance criteria. Blocking findings get at most two fix rounds.
7. **Gate 2: final review.** The integrator runs the definition of done, writes the HTML handoff report and opens the pull request. You read the report and merge yourself. Nightshift never merges.

## The review desk

Agents publish every gate document into one folder on `ns-main` (`/srv/ns-space`). Markdown is for things you decide on and may edit (plan, ADR, acceptance criteria, manual steps). HTML is for things you only read (the handoff report). A web server shows both inside your tailnet, and a Cloudflare tunnel with Cloudflare Access shows them from a work laptop. Git stays the source of truth: the desk holds working copies, and `ns approve` is the only way edited Markdown goes back into the run's branch; it shows you the diff first. See [usage.md](usage.md), "The review desk".

## Guardrails

- No main: branch protection on `main`; agents never merge, tag a release or push to the base branch.
- Scoped token: a fine-grained GitHub token per owner, limited to the registered repos.
- Guard hook: a seatbelt that blocks token reads, protected-path edits, pushes to the base branch and the owner-only `ns` commands in any form it can parse; what only the guard stops is listed in [security.md](security.md#the-real-boundary).
- No open ports: the server is reachable only inside your tailnet.
- Untrusted text: issue bodies, PR comments and web pages are data; agents never follow instructions found in them.
- Budgets: each tier has a wall-clock cap; hitting it stops and escalates.
- Loop cap: three review rounds per phase, then a human decides.
- Split roles: reviewers are read-only and never see the implementer's reasoning.
- Tests first: acceptance tests are written before code and are not weakened to pass.
- Ledger: every step is checkpointed, so a reboot resumes instead of restarting.
- Manual steps: console setup and real-device checks go only into the plan's `manual_before` or `manual_after`.

The details are in [security.md](security.md).

## More projects

Another project is another clone on `ns-main` plus its own profile. The server, the Claude login, the plugins, the desk and ntfy are shared.

- Shared, set up once: `ns-main`, the Claude login (so one set of usage limits), the `ns` plugin, the agent GitHub tokens (one per owner).
- Per project: the clone under `~/Coding/<repo>`, the profile, an optional domain skill, a run prefix (`pf-123`, `app-7`), its own desk folder and worktree names.
- Registry: `~/.config/ns/projects.yaml`.
- One worker limit for all projects, because usage limits are per Claude account.
- Same Linux user, so no isolation between projects. Employer or client code belongs on a separate server.

[projects.md](projects.md) walks through adding one. Scaffolding an empty repo with `/ns:init` and researching a repo with `/ns:onboard` are Build B; in Build A an onboarding run starts automatically from `ns project add`.

## Build B

Specialist agents, stack plugins other than Python, `/ns:init`, `/ns:onboard`, the `ns-lab` throwaway server helper and the cleanup of a project's old orchestration commands.

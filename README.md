# Nightshift

Nightshift is a personal, adaptive, multi-agent coding framework built on the Claude Code CLI. It runs unattended on one Linux server. A typo fix runs one short session; a feature runs planning, parallel implementation and a review board, and triage picks the depth.

It is for a single owner who starts work and reviews it from an iPad or a browser, checking a plan at gate 1 and the result at gate 2. The core knows no project and no language: project facts live in each project's repo, and language facts live in stack plugins.

Status: v0.1.0 (Build A)

## What it needs

- A server running Ubuntu 24.04 with root for the one-time setup and a normal user `ns` (no sudo) for the agents; 4 GB RAM is enough for 2 workers.
- The Claude Code CLI signed in with a subscription.
- Tailscale for private access; Cloudflare with a domain if you want the review desk from a laptop without Tailscale.
- A GitHub account and a fine-grained token per repo owner for the agents.
- `git`, `gh`, `tmux`, `jq` and Python 3 (installed by `bootstrap.sh`, see [docs/setup.md](docs/setup.md)).

## Five-minute tour

Once the server is set up ([docs/setup.md](docs/setup.md)):

1. Register a project: `ns project add owner/repo --prefix app`. If the repo has no profile yet, an onboarding run starts and publishes drafts; `ns approve app-onboard` opens the pull request, you merge it ([docs/projects.md](docs/projects.md)).
2. Start work: `ns new app-12` runs GitHub issue 12, or `ns new app "fix the typo in the README"` runs free text. Triage proposes a tier and you confirm.
3. See what is going on: `ns ls` lists runs with tier, state and gate. `ns status app-12` reads the ledger.
4. Watch or answer: `ns attach app-12` jumps into the run's tmux session. Detach with Ctrl-b d; the run keeps going. `ns log app-12` reads the session log.
5. At a gate you get a push notification. The plan or report is on the review desk: edit the Markdown in a browser, read the HTML report.
6. Release the gate: `ns approve app-12` shows your edits as a diff, commits them and continues the run. At the end you get a pull request; you merge it yourself.

## Documents

- [Architecture](docs/architecture.md): how the pieces fit.
- [Accounts](docs/accounts.md): the accounts and tokens, and what was set up.
- [Server](docs/server.md): the server and its services.
- [Setup](docs/setup.md): `bootstrap.sh` and the manual steps.
- [Using Nightshift](docs/usage.md): every `ns` command, tiers, gates, the desk.
- [Operations](docs/operations.md): reboots, housekeeping, upgrades.
- [Security](docs/security.md): the trust boundary and the guardrails.
- [Adding a project](docs/projects.md): tokens, onboarding, first smoke test.
- [Profile reference](docs/profile-reference.md): every key of `project-profile.yaml`.
- [Agents and skills](docs/agents.md): who does what.
- [The conductor](docs/conductor.md) and [the ledger](docs/ledger.md): internals.
- [Development guide](docs/development.md)
- [Specification](docs/spec.md) and [build plan](docs/build-plan.md)
- [Architecture decision records](docs/adr/)
- [Changelog](CHANGELOG.md)

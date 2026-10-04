# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `ns log <id> [-f] [--phase <p>] [--raw]` shows a run's session logs as readable, wrapped text.
- `ns-notify` sends the ntfy bearer token (via curl stdin) and fails on a non-2xx answer; the Caddyfile template serves ntfy on `:8444`.

### Fixed

- The session stream view no longer truncates tool input at 120 characters; it wraps to the terminal width with a hanging indent and shows tool results as one short line (issue #44).
- `ns-conductor checks` writes `logs/<id>/<target>.checks.rc` with its exit code on every path, and the conductor prompts forbid `pgrep` wait loops that matched themselves and never ended (ns-x2).
- `ns-notify` sends text literally with `--data-raw`, so text starting with `@` is no longer read as a file (issue #7).

## [0.1.0] - 2026-10-02

### Added

- Plugins and agents: the `ns` plugin with agents (triage, conductor, implementer, code-reviewer, integrator, planner, product-analyst, architect, test-architect, researcher, sec-compliance) and skills for running, planning, implementing, reviewing, resuming and reporting (`/ns:run`, `/ns:plan`, `/ns:implement`, `/ns:dod`, `/ns:status`, `/ns:resume`, `/ns:review`); the `ns-python` stack plugin with Python conventions, packaging and testing skills.
- The ns CLI and helpers: the `ns` dispatcher with `ns help`, `ns new`, `ns ls`, `ns status`, `ns attach`, `ns stop`, `ns project`, `ns profile`, `ns publish` and `ns approve`; the common bash library, the `nsyaml.py` YAML helper, `ns-launch` and `ns-conductor` (worker pool, branches, checks, review rounds, merge, gates, finish, pause).
- Profile and schema: the project profile schema, stack schema and ledger schema, `ns profile check` and `ns profile show`, a generated profile reference, example profiles and the Python CI template.
- Ledger and resume: the per-run ledger (`ns-ledger`) kept on `plan/<id>` for every tier (ADR 0002) and `ns resume`, which adopts detached workers (ADR 0008).
- Desk and notifications: `ns publish`, the desk index and `ns-notify`.
- Hooks: guard (fails open, ADR 0006), checkpoint and session-start hooks.
- Operations (drain, up, gc, doctor): `ns drain`, `ns up` with systemd unit templates, `ns gc` housekeeping with a timer, and `ns doctor`.
- ns-gh: the `ns-gh` wrapper around `gh` with repository name validation, tested against a gh stub.
- Bootstrap: `bootstrap.sh` with `--check`, the server setup steps, a Caddyfile template, release install under `/opt` and `--upgrade`.
- Tests and CI: bats suites in `tests/bats`, `tests/lint`, `tests/docs-check` (including `--final`) and a GitHub Actions workflow; stubs for `tmux`, `claude` and `gh`.
- End-to-end harness: `tests/e2e/run.sh` with scenarios t0, t1, t2, t3 and resume against `andras-tkcs/nightshift-sandbox`, run with `--keep` in Build A (ADR 0009); results in `tests/e2e/results.md`.
- Documentation: the specification, build plan, architecture, usage, ledger, conductor, agents, projects, accounts, server, operations, security, setup and development guides, and architecture decision records 0001 to 0009. The `v0.1.0` tag is set by the owner after merge (ADR 0007).

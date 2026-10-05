# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.5] - 2026-10-05

### Added

- `ns tag <vX.Y.Z>` tags and pushes a release after checking that main is clean and equal to origin, the version is the next step, the tag is new and the project checks pass; it warns on CI that is not green and prints the upgrade command. The guard blocks agents from running it (issue #50).
- Stacked PRs, part 1: `ns-conductor stack-base <id>` merges the top open run PR into the run's branch and prints the PR base (exit 6 on a conflict), the ledger records `stacked_on`, `ns stack [project]` lists the stack bottom to top, `ns status` shows a `stacked` line, and the integrator opens the PR against the stack top (issue #73). The end-to-end scenario is still to do.

## [0.1.4] - 2026-10-05

### Added

- Runs keep the Nightshift release they started on: the ledger records `release`, `ns resume` and `ns-launch` use it (failing clearly if it is gone), `ns status` shows it, and `bootstrap.sh --upgrade` refuses while runs are active unless `--force`. A ledger `release` that is not a tag is refused, and runs whose ledger cannot be read count as active for the upgrade check (ns-46).
- `ns-conductor note` records follow-ups in `RUN/notes.md` (listed in the PR body) and `ns-conductor report --rerun` regenerates a phase report record; `ns status` and the gate 1.5 notification show the escalation question (issue #47).

## [0.1.3] - 2026-10-05

### Added

- `ns kill <id>` ends a run's session, conductor and worker process groups at once and marks it `stopped`; the guard blocks agents from running it (ns-42).
- `ns ls` and `ns status` show run health (`ok`, `dead`, `silent <N>m`) and `ns ls` has ELAPSED and LAST-OUT columns; `ns health-check` and the `ns-health.timer` notify once per dead or silent run (issue #43).
- `ns rm <id>` (alias `ns purge`) removes a stopped, failed, parked or done run: worktrees, branches, tmux session and desk folder, with `--remote`, `--force`, `--dry-run`, `--yes` and `--all-stopped` (issue #60).
- `ns log <id> [-f] [--phase <p>] [--raw]` shows a run's session logs as readable, wrapped text.

### Fixed

- `ns-conductor checks` runs each check in a clean environment with no `NS_*` variables (issue #37), writes a non-zero `.rc` marker when the body dies or a check fails (issue #39), and reports a pytest exit 5 as `SKIP` instead of `FAIL`. `report` accepts a short head sha that is a prefix of the real head.
- `ns-conductor merge` detects an already merged phase on long histories; the `git log | grep -q` pipe failed under pipefail (issue #40).
- `ns stop` on a run with no live conductor (at a gate, or dead) now stops it at once instead of waiting for a checkpoint that never comes (ns-42).
- `stream-view.py` survives malformed events and a closed stdout instead of killing the conductor's pipe (issue #43, #13).
- The session stream view no longer truncates tool input at 120 characters; it wraps to the terminal width with a hanging indent and shows tool results as one short line (issue #44).

## [0.1.2] - 2026-10-04

### Changed

- The bats suite no longer inherits `NS_CMD` and `NS_NTFY_URL` from the caller, and a pytest unit suite covers the `nsyaml`, manifest and profile libraries (part of issue #37).

### Fixed

- `ns publish` checks the whole HTML file instead of single lines, so a tag split over several lines no longer slips past the self-containment check (issue #5, part 1; the Content-Security-Policy header is still to do).

## [0.1.1] - 2026-10-04

### Added

- `ns-notify` sends the ntfy bearer token (via curl stdin) and fails on a non-2xx answer; the Caddyfile template serves ntfy on `:8444`.

### Changed

- Nightshift's own profile protects workflow files, and CI is pinned to ubuntu-24.04 (issue #21).
- The build plan and specification cover usage monitoring and the self-hosted ntfy for Build B.

### Fixed

- `ns-conductor checks` writes `logs/<id>/<target>.checks.rc` with its exit code on every path, and the conductor prompts forbid `pgrep` wait loops that matched themselves and never ended (ns-x2).
- `ns-notify` sends text literally with `--data-raw`, so text starting with `@` is no longer read as a file (issue #7).
- `ns project add` adopts an existing clone only when its origin matches the repository name after a `/` or `:`, so `evilacme/widget` no longer matches `acme/widget` (issue #8).

## [0.1.0] - 2026-10-03

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

[Unreleased]: https://github.com/andras-tkcs/nightshift/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/andras-tkcs/nightshift/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/andras-tkcs/nightshift/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/andras-tkcs/nightshift/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/andras-tkcs/nightshift/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/andras-tkcs/nightshift/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/andras-tkcs/nightshift/releases/tag/v0.1.0

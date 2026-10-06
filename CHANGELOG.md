# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- `ns-conductor report --rerun` can no longer certify a phase the worker never finished: it refuses a phase branch with no commits beyond the feature branch and records a `report-rerun` event (shown by `ns status` and the run report). `review-round` records its verdict and the phase head it reviewed, and refuses (exit 2) a verdict that contradicts the last line of `RUN/review-<phase>-<n>.md`; `merge` exits 8 unless the last round approved exactly the current phase head. The e2e t1 scenario matches Claude Code's own auto mode classifier denial text and reads `notes.md` from the run's worktree (issue #71).
- `ns new --from-desk` resolves the path and refuses a file outside the desk directory unless `--allow-outside` is given, and refuses a note that looks like it contains a token; the guard blocks agents from running `ns desk` (issue #95).

### Changed

- `ns stack` and `ns-conductor stack-base` treat a base as closed only when the closed PR was closed at or after the dependent PR was created and no open PR has that head name; a fork of run PRs is now several chains (`stack-base` exits 7); the stack e2e scenario only counts open PRs of runs with a `plan/<run id>` branch as leftovers (issue #97).

- CI is split into parallel jobs `lint`, `bats` and `plugin-validate`, plus an aggregate job `checks` (the required status check, unchanged) that fails unless all three succeed, so lint failures no longer wait behind the bats suite (issue #103).
- `ns_ledger_read` validates and parses a ledger in one Python launch (new `nsyaml.py read <file> <schema.json>`), halving the launches per ledger read (issue #101).
- The bats suite runs in parallel: CI installs GNU `parallel` and runs `bats --jobs "$(nproc)"`, and CLAUDE.md and docs/development.md document `bats --jobs 2` for local runs (issue #102).

### Added

- `ns stack merge [project] [--dry-run]` lands the stack bottom to top (the profile checks run once on the top of the stack first; each PR needs an approval, no failing checks and no conflicts; the next PR is retargeted to the base branch before the one below is merged; it stops at the first PR that is not ready and lists what is left), and `ns stack drop <id> [--dry-run]` closes a run's PR, restacks the PR above it onto the layer below and reverts the dropped change in it (it stops and names the PR when the revert does not apply). Both are blocked for agents (issue #74).
- `ns report <id>` writes `runs/<id>/run-report.md` from the run ledger: a summary (wall, active and waiting time, budget, review rounds, escalations) and a timeline with one row per step. It is written automatically when a run finishes or is killed, published to the desk at finish and linked from the PR body; it reads `origin/plan/<id>` when the worktree is gone (issue #64).
- `tests/lint` guards against jq version drift: it fails on a bare `reduce`/`foreach` expression followed by `as $name` (accepted by jq 1.8, rejected by CI's jq 1.7.1; write `(reduce ...) as $name`) and warns when local jq differs from CI; `NS_LINT_STRICT_JQ=1` makes the warning a failure (issue #105).
- `max_runs` (config, default 2) limits live run conductors: `ns new`, `ns resume`, `ns resume --all` and `ns approve` queue a run past the limit, the new `ns dequeue` starts queued runs oldest first when a conductor ends, `ns new --now` skips the limit, `ns ls` shows `runs` in WAITING-ON and `ns status` the queue position (issue #75).
- `ns new <prefix> --from-desk <path.md>` starts a run from a desk note (the request is copied into the ledger; nothing in the repo, no PR), and `ns desk import <path.md> <repo path>` lands a desk note in the repo via a pull request that is never merged (issue #76).
- Stacked PRs, follow-ups: a run PR needs `plan/<run id>` on origin and `{n}` matches digits only; `stacked_on` records the profile base branch; `stack-base` refuses to merge over untracked files and exits 7 (gate 1.5) when open run PRs form more than one chain; `ns stack` prints each chain and marks a PR whose base was closed unmerged (`base closed`), and `stack-base` warns about it; new `stack` e2e scenario (issue #84).
- `ns tag` warns when Nightshift runs are active, since `bootstrap.sh --upgrade` refuses while they are, and its docs name the profile's base branch instead of `main` (issue #80).

### Fixed

- The review-round cap no longer costs an extra review. Interface change: `ns-conductor review-round <id> <phase> <approve|changes>` now needs the review's verdict (a two-argument call exits 2; the bundled skills pass it). An approval always proceeds (a T2 approval on round 3 merges), and `changes` exits 7 when the count reaches `budgets.<tier>.review_rounds`, so at most that many reviews run; the run report's timeline label leaves the verdict out (issue #12).
- `ns-conductor wait` treats a worker as hitting a usage limit only when its last `result` is an error (`is_error` or a non-success `subtype`) whose message starts with one of Claude Code's limit texts, which now includes the current "You've hit your session limit · resets ..." text; a successful report that mentions a rate limiter, or an error for another reason, is a normal finish. A usage limit pauses the budget until the reset time (`budget.paused_until`; 15 minutes doubling to at most 4 hours when no time can be read), `start` exits 8 meanwhile, the conductor parks the run and `ns health-check` resumes it after the reset, instead of restarting the phase in a loop. A limit that does not reset (spend limit, no usage credits) or the fourth limit of a phase escalates to gate 1.5. When the conductor's own session ends on a usage limit, `ns-launch` pauses and parks the run (or escalates a limit that does not reset), and it also parks a run that `wait` had paused when the conductor died before parking; `ns health-check` runs `ns dequeue` first and then wakes such runs (parked, or running with a dead conductor, never at a gate), reporting resumed and queued ones separately; `ns stop` stops a run parked on a usage limit for good. A conductor launch after `paused_until` clears the pause (the wall-clock budget counts again), and the fourth conductor-side usage limit without progress escalates to gate 1.5. A capacity 429 or a 529 overload is retried once after a minute (`wait` prints `retry <phase>` when it is due), then takes the normal failure path (issue #11).
- A ledger with an unknown top-level key (schema drift between releases) is read with a warning `ledger has unknown field <k>; kept` instead of being treated as corrupt; missing fields and wrong types stay errors, and the message names the field and points to `ns-ledger validate <ledger>`. A Nightshift command started from a checkout that is not an installed release (`NS_HOME` differs from `NS_RUN_HOME`, the home that launched the run) refuses to write the ledger of the live run marked by `NS_RUN_ID` and `NS_LEDGER`; temp ledgers stay allowed (issue #83).

## [0.1.5] - 2026-10-05

### Added

- Stacked PRs, part 1: `ns-conductor stack-base <id>` merges the top open run PR into the run's branch and prints the PR base (exit 6 on a conflict), the ledger records `stacked_on`, `ns stack [project]` lists the stack bottom to top, `ns status` shows a `stacked` line, and the integrator opens the PR against the stack top (issue #73). The end-to-end scenario is still to do.
- `ns tag <vX.Y.Z>` tags and pushes a release after checking that main is clean and equal to origin, the version is the next step, the tag is new and the project checks pass; it warns on CI that is not green and prints the upgrade command. The guard blocks agents from running it (issue #50).

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

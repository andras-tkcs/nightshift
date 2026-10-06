# Developing Nightshift

## Load the plugins from the checkout

```bash
claude --plugin-dir ./plugins/ns --plugin-dir ./plugins/ns-python
```

## Run the checks

```bash
tests/lint
bats --jobs 2 tests/bats
claude plugin validate --strict .
tests/docs-check --final
```

`tests/lint` runs shellcheck over every script. `bats --jobs 2 tests/bats` runs the unit suite in parallel (needs GNU `parallel`, `sudo apt-get install parallel`; CI uses `--jobs "$(nproc)"`). Without `--jobs` it is serial and takes 20 minutes or more, so run single files while you work. Tests work with stdin closed or open: the `claude` stub reads stdin with a 2 second timeout. `claude plugin validate --strict` checks the marketplace and both plugins. `tests/docs-check --final` checks that every command and slash command is documented and that links resolve; CI runs it with `--final`. CI (`.github/workflows/ci.yml`) runs the parallel jobs `lint`, `bats` and `plugin-validate` (plugin validation and docs-check), so a lint or manifest failure shows up without waiting for bats; the aggregate job `checks` needs all three and is the required status check (`REQUIRED_CHECKS="checks"`), so keep that name.

## End-to-end runs

End-to-end tests run on ns-main only and touch only `andras-tkcs/nightshift-sandbox`, never any other repository. They start real runs with Claude, so they use your Claude usage and take time.

```bash
tests/e2e/run.sh preflight          # gh login, sandbox repo, auto mode, bats, shellcheck, memory
tests/e2e/run.sh t0                 # one scenario: t0, t1, t2, t3, stack or resume
tests/e2e/run.sh cleanup <branch>   # remove what a failed attempt left behind
```

Cost grows with the tier: `preflight` uses almost no usage, `t0` and `t1` take minutes and a little usage, `t2` and `t3` take much longer and use a lot, `stack` runs two T0 runs in a row and checks that the second pull request is stacked on the first (its base is the first branch and its diff shows only its own change), and `resume` kills a conductor and resumes it. Each run appends a line to `tests/e2e/results.md`. `--keep` leaves the pull request and branches in place after a pass. Run one scenario at a time (4 GB RAM).

`tests/e2e/pool-watch.sh [--config-dir <dir>] [--interval <s>] [--once]` watches the worker pool of one Nightshift home (default `$NS_CONFIG_DIR`): every few seconds it prints the live workers by pid file (the count `ns-conductor start` uses), the `ns-worker` processes started for that home and the most seen, and `max live workers seen: <k>` when stopped. It only reads. Use it to check that `max_workers` holds while several runs share one home.

## Conventions

- Bash executables start with `#!/usr/bin/env bash` and `set -euo pipefail`, and are shellcheck clean.
- Every executable has `--help` (exit 0) and exits 0 on success, 1 on failure, 2 on a usage error.
- Sourced libraries in `bin/lib/*.sh` start with `# shellcheck shell=bash`, never call `set`, and define only functions and constants.
- Errors go to stderr as `<command>: <message>`; times are UTC ISO-8601 from `ns_now`.
- No command prints, logs or commits a token.

The requirements are in [spec.md](spec.md).

## Developing Nightshift with Nightshift

A run on this repo executes the installed release while the checkout holds work in progress. New or changed `bin/` commands must only be run against test fixtures or temp ledgers, never with the run's own `$NS_LEDGER`. Nightshift enforces this for writes: a command whose `NS_HOME` differs from `NS_RUN_HOME` refuses to write the live run's ledger. Unknown ledger fields are read with a warning, so one release of schema drift does not lock a run out (see `docs/ledger.md`).

## Releasing

Releases are tagged by the owner, never by an agent (ADR 0007).

1. In a pull request, move the `[Unreleased]` entries of `CHANGELOG.md` to a new version section `[X.Y.Z]` with the date, and leave an empty `[Unreleased]` above it. Get it reviewed and merged.
2. The owner tags `main` and pushes the tag:

   ```bash
   git fetch origin
   git tag -a vX.Y.Z -m "Nightshift X.Y.Z" origin/main
   git push origin vX.Y.Z
   ```

3. Install the release on the server: run `bootstrap.sh` (steps 8 and 9 install the release and the plugins), or follow the update steps in [operations.md](operations.md#updates) (`bootstrap.sh --upgrade vX.Y.Z`).

## jq version drift

CI runs jq 1.7.1; dev machines may have a newer jq (1.8.1 here). jq 1.7 rejects a bare `reduce`/`foreach` expression used as a binding source, as in `reduce .[] as $x (0; . + $x) as $t`, while jq 1.8.1 accepts it, so it passes locally and fails in CI. `tests/lint` fails on that form (write `(reduce .[] as $x (0; . + $x)) as $t`) and prints a warning when local `jq --version` differs from 1.7.1. Set `NS_LINT_STRICT_JQ=1` to make that warning a failure. `NS_LINT_ROOT` points the lint at another tree (used by `tests/bats/lint-jq.bats`).

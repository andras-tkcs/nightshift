# Developing Nightshift

## Load the plugins from the checkout

```bash
claude --plugin-dir ./plugins/ns --plugin-dir ./plugins/ns-python
```

## Run the checks

```bash
tests/lint
bats tests/bats
claude plugin validate --strict .
tests/docs-check --final
```

`tests/lint` runs shellcheck over every script. `bats tests/bats` runs the unit suite and takes 20 minutes or more, so run single files while you work. Tests work with stdin closed or open: the `claude` stub reads stdin with a 2 second timeout. `claude plugin validate --strict` checks the marketplace and both plugins. `tests/docs-check --final` checks that every command and slash command is documented and that links resolve; CI runs it with `--final`.

## End-to-end runs

End-to-end tests run on ns-main only and touch only `andras-tkcs/nightshift-sandbox`, never any other repository. They start real runs with Claude, so they use your Claude usage and take time.

```bash
tests/e2e/run.sh preflight          # gh login, sandbox repo, auto mode, bats, shellcheck, memory
tests/e2e/run.sh t0                 # one scenario: t0, t1, t2, t3 or resume
tests/e2e/run.sh cleanup <branch>   # remove what a failed attempt left behind
```

Cost grows with the tier: `preflight` uses almost no usage, `t0` and `t1` take minutes and a little usage, `t2` and `t3` take much longer and use a lot, and `resume` kills a conductor and resumes it. Each run appends a line to `tests/e2e/results.md`. `--keep` leaves the pull request and branches in place after a pass. Run one scenario at a time (4 GB RAM).

## Conventions

- Bash executables start with `#!/usr/bin/env bash` and `set -euo pipefail`, and are shellcheck clean.
- Every executable has `--help` (exit 0) and exits 0 on success, 1 on failure, 2 on a usage error.
- Sourced libraries in `bin/lib/*.sh` start with `# shellcheck shell=bash`, never call `set`, and define only functions and constants.
- Errors go to stderr as `<command>: <message>`; times are UTC ISO-8601 from `ns_now`.
- No command prints, logs or commits a token.

The requirements are in [spec.md](spec.md).

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

CI runs jq 1.7.1; dev machines may have a newer jq that accepts syntax 1.7 rejects. `tests/lint` therefore fails on `reduce`/`foreach` whose source is an unparenthesised pipeline before `as` (write `reduce (.a | .[]) as $x (...)`), and prints a warning when local `jq --version` differs from 1.7.1. Set `NS_LINT_STRICT_JQ=1` to make that warning a failure. `NS_LINT_ROOT` points the lint at another tree (used by `tests/bats/lint-jq.bats`).

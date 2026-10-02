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
tests/docs-check
```

## Conventions

- Bash executables start with `#!/usr/bin/env bash` and `set -euo pipefail`, and are shellcheck clean.
- Every executable has `--help` (exit 0) and exits 0 on success, 1 on failure, 2 on a usage error.
- Sourced libraries in `bin/lib/*.sh` start with `# shellcheck shell=bash`, never call `set`, and define only functions and constants.
- Errors go to stderr as `<command>: <message>`; times are UTC ISO-8601 from `ns_now`.
- No command prints, logs or commits a token.

The requirements are in [spec.md](spec.md).

## Releasing

Written in the release phase.

# 0004. YAML is handled by a Python helper and jq

## Status

Accepted

## Context

Profiles, registries and ledgers are YAML, and the tooling is bash.

## Decision

YAML is handled by a small Python helper (`nsyaml.py`, PyYAML) plus `jq`.

Rejected alternatives:

- `yq`: it is not on ns-main, and two incompatible tools share the name.
- Hand-written bash parsing.

## Consequences

One well-tested parser, and `jq` for JSON. PyYAML becomes a dependency of the server.

## Notes

2026-10-06: a list of the helper's subcommands had been added to the Decision section after the ADR was accepted (issue #101). The Decision is back to its accepted text; the subcommands are listed in `docs/architecture.md` (issue #120).

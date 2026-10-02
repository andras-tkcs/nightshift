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

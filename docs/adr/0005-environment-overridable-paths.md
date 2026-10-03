# 0005. All paths are overridable by environment

## Status

Accepted

## Context

Tests must never touch the owner's real configuration, desk or checkouts.

## Decision

All paths are overridable by environment (`NS_CONFIG_DIR`, `NS_DESK_DIR`, `NS_CODING_DIR`, `NS_PLUGIN_DIRS`), so bats and end-to-end runs never touch the owner's real state.

Rejected alternatives:

- Containers: there is no root on ns-main.

## Consequences

Tests are isolated by setting variables. Every new path in the code must go through these variables.

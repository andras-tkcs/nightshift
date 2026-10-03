# 0002. Run ledger lives on plan/<id> for every tier

## Status

Accepted

## Context

R-LED-1 put the ledger on the run's working branch, which for T0 and T1 is the fix branch. That branch becomes the project's pull request, so a ledger file and `ns-ledger:` commits would land on the project's `main`.

## Decision

The ledger lives on `plan/<id>` for every tier. T0/T1 code goes to a separate `fix/<id>` worktree. This amends R-LED-1. `ns-conductor feature` cuts the feature branch from `origin/<base>` and copies over only the plan document and acceptance tests, so no project PR carries a ledger file or an `ns-ledger:` commit.

Rejected alternatives:

- Ledger on the fix branch: it would land on the project's `main`.
- Ledger outside git: it breaks R-LED-4 (resume from the ledger).

## Consequences

Every run has one ledger location regardless of tier, and project pull requests stay clean. T0/T1 runs need a second worktree.

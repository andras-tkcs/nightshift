# 0009. Build A's end-to-end scenarios keep their PRs

## Status

Accepted

## Context

The owner reviews what the scenarios produced (build-plan, "Build A is done when" 2).

## Decision

Build A's end-to-end scenarios run with `--keep`, so their PRs and base branches stay on the sandbox for the owner to read. The harness's default still deletes everything (spec section 16).

Rejected alternatives:

- Deleting them and only recording URLs: the PRs would be gone at Review 1.

## Consequences

The sandbox accumulates PRs and branches until the owner cleans them up.

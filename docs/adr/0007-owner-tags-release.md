# 0007. The owner tags v0.1.0 after the PR merges

## Status

Accepted

## Context

The release phase runs before the final review and the pull request. Changes can still follow it.

## Decision

`v0.1.0` is tagged by the owner on `main` after the PR merges. The release phase only writes the CHANGELOG section. This also replaces make-plan's final check "CHANGELOG has no version heading": the PR carries a `## [0.1.0]` section by design.

Rejected alternatives:

- Tagging in the release phase: the final review and PR changes come after it, so the tag would point at an unreviewed commit.

## Consequences

The tag always points at the merged, reviewed commit. The owner has one manual step after the merge.

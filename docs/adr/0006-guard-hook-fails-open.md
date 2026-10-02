# 0006. The guard hook fails open

## Status

Accepted

## Context

The guard hook inspects tool calls before they run. Its input format belongs to Claude Code and may change.

## Decision

The guard hook fails open on input it cannot parse. The boundary is the token scopes and the branch rulesets; the guard is a seatbelt.

Rejected alternatives:

- Fail closed: a Claude Code input-format change would stop every session on the machine.

## Consequences

A format change degrades the seatbelt but not the machine. Safety must never depend on the guard alone.

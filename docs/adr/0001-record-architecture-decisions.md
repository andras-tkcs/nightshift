# 0001. Record architecture decisions

## Status

Accepted

## Context

Nightshift makes decisions that are hard to see later from the code alone: trust boundaries, the release path, rejected alternatives. Agents and the owner both need to find the reasons.

## Decision

We record such decisions as short ADRs in `docs/adr/`, in the format described by Michael Nygard: Status, Context, Decision, Consequences.

## Consequences

Decisions have a durable, reviewable home. Each ADR costs a little writing time, and superseded decisions stay in the history.

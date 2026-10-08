# 0011. Owner notes reach the conductor through the ledger

## Status

Accepted

## Context

The owner had no way to steer a running run except `ns stop` or a gate. A new instruction channel into the conductor moves a trust boundary, so it meets the bar in `docs/adr/README.md`.

## Decision

The owner-only `ns note <id> "text"` appends a timestamped note to the new ledger field `owner_notes` and an `owner-note` event, committed and pushed. The conductor reads unread notes at its between-step checkpoint with `ns-conductor owner-notes <id>`, follows them over the plan's scope and acceptance criteria, never over gates, the guard or protected paths, and marks them read. `ns report` lists them.

Rejected alternatives:

- Reuse `ns-conductor note`: it points the other way (conductor to owner) and renaming it breaks skills.
- Fold notes into `should-stop` output: its 0/1/4 exit codes are a contract.
- A separate notes file: the ledger already has the lock, the schema, the commit and the push, and the report reads it.
- Plain `checkpoint` like `ns stop`: the request asks for a push.
- `--arg` on `ns-ledger set`: a wider interface change than needed.
- Guard agent writes to `owner_notes` (the guard blocks `ns-ledger set` programs and Edit/Write on `ledger.yaml` that name it): `ns-ledger set` stays open to agents, as for `stop_requested`. The bound on what a note can do is the control, not a block on who writes it.

## Consequences

A fooled agent can write a note itself. A note cannot release a gate, lift the guard or allow edits to protected paths. It can widen scope, though: unlike `stop_requested`, which can only reduce work, a forged note can ask for more, so the security review of a run treats `owner_notes` as untrusted when the writer was not `ns note`. Notes are append-only and listed in `ns report`. A note to a run with no live conductor is read at the start of its resumed session.

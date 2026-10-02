# 0003. Conductor sessions are headless in tmux

## Status

Accepted

## Context

A conductor needs to run unattended for hours inside tmux.

## Decision

Conductor sessions are headless (`claude -p`) in tmux. The owner steers through the desk and `ns approve`, and `ns new` asks the tier question before detaching.

Rejected alternatives:

- Interactive sessions: they block on the workspace-trust dialog in every new worktree, and editing `~/.claude.json` to pre-trust is fragile.

## Consequences

No dialog can stall a run. The owner cannot type into a running conductor; all steering goes through the desk.

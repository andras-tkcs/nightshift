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

## Notes

2026-10-06 (issues #16, #58, #81, #117): the decision stands for input the guard cannot read and for errors inside it, which still let the action through with `ns guard: not checked`. Two things changed around it. A shell command line the guard can read but not fully resolve is now refused when it may hide an owner-only command (a command name or `ns` subcommand built at run time, `eval` or `sh -c` of such a string, a pipe into a shell, a script that does not exist yet, a line it cannot parse that names an owner-only subcommand); this is failing closed for a narrow, known class of text, not for unknown input, so a format change still cannot stop every session. And `protected_paths` and the base branch now come from the profile on `origin/<base>`, the worktree's file only when origin has none. The review also showed that the boundary is narrower than this record assumed: the rulesets stop pushes to the default branch, but nothing on GitHub stops the agent token from merging an open pull request or pushing a tag, and local owner commands (`ns kill`, `ns approve`, ...) have no boundary but the guard; docs/security.md, "The real boundary", lists what stops what.

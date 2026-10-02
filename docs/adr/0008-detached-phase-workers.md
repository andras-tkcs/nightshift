# 0008. Phase workers run detached

## Status

Accepted

## Context

A conductor crash must not lose running workers or their exit status.

## Decision

Phase workers run detached (`setsid`) with pid and exit files in `$NS_CONFIG_DIR/workers`, so a conductor crash leaves them running and `ns resume` adopts them.

Rejected alternatives:

- Workers as children of the conductor: a `kill -9` would orphan or kill them and lose their exit status.

## Consequences

Resume can adopt live workers and read finished ones. The pool must track pid and exit files.

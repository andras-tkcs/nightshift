## Summary

Adds `ns note <id> "text"`, an owner-only command that appends a timestamped note to the new ledger field `owner_notes` (plus an `owner-note` event), committed and pushed. The conductor reads unread notes at its between-step checkpoints with `ns-conductor owner-notes <id>`, follows them over the plan's scope (never over gates, the guard or protected paths), marks them read, and `ns report` lists them under `## Owner notes`. The guard blocks agents from running `ns note`. ADR 0011 records the decision. Docs: usage, ledger, conductor, security, spec.

Owner decision: phase p3-retire was not registered; its content (ADR 0011, README row, changelog entry, retiring `docs/ns-x7-plan.md`) was done at integration. `docs/security.md` now says a stop can only reduce work while a forged note can widen scope.

## Phases

- p1-note-cli: `ns note`, schema, `ns-conductor owner-notes`, report section (merge 056cab2)
- p2-guard-skill: guard blocks `ns note` for agents; conductor skills read notes (merge 58b95c3)
- integration: ADR 0011, changelog, security.md, plan retired (486e74a)

## Checks

| Check | Result |
|---|---|
| `tests/lint` | PASS |
| `tests/docs-check --final` | PASS |
| `bats --jobs "$(nproc)" tests/bats` | FAIL: 909 ok, 1 timing flake: `ns_kill_group gives up after about 2 s` (kill.bats:200) under load average 22 to 29 from other runs; `bats tests/bats/kill.bats` passes alone; the diff does not touch kill |
| profile `docs.dod`, typecheck, audit | n/a (not set) |

Full table: `.nightshift/runs/ns-x7/dod.md` on the plan branch.

## Non-blocking findings and open items

- `tests/bats/ledger.bats:160` clean-tree assertion never failed first.
- `bin/ns-ledger` ~228: a push-failed commit via `git_retry` can exit non-zero, contradicting "still exits 0".
- AC-4: the library-code guard message reads "is the owner's to run" (plan Q2), not "ns note is the owner's command".
- `ns-conductor owner-notes` can be run by any agent or worker, including marking notes read; consider refusing when `NS_WORKER` is set.
- Only CR/LF are folded in note text; other control characters and U+0085/2028/2029 pass.
- Concurrent `ns note` calls may mislabel event `n`.
- `checkpoint --push` pushes to the ledger `.branch`.
- `plugins/ns/hooks/lib/guard.py:402` comment line is long.
- Security caveat (ADR 0011): agents can still write `owner_notes` with `ns-ledger set`; a forged note can widen scope but cannot release a gate, lift the guard or touch protected paths.

## Follow-ups

- follow-up: ledger.bats:160 clean-tree assertion never failed first; tighten it
- follow-up: bin/ns-ledger ~228 push-failed commit via git_retry can exit non-zero, contradicting 'still exits 0'
- follow-up: AC-4 library-code guard message says 'is the owner's to run' (plan Q2 decision), not 'ns note is the owner's command'
- follow-up: ns-conductor owner-notes can be run by any agent or worker including marking notes read; consider refusing when NS_WORKER is set
- follow-up: ns note folds only CR/LF in note text; other control chars and U+0085/2028/2029 pass
- follow-up: concurrent ns note calls may mislabel event n
- follow-up: checkpoint --push pushes to the ledger .branch; refuse base/default branch
- follow-up: plugins/ns/hooks/lib/guard.py:402 comment line is too long

## Manual verification

None.

## Stack

Base `main`; no other run PR is open.

## Run report

`.nightshift/runs/ns-x7/run-report.md` on branch `plan/ns-x7`.

## Desk link

Published by `ns-conductor finish` (see `ns status ns-x7`).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

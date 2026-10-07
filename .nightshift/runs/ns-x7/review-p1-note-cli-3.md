# Review p1-note-cli, round 3

Range: `origin/feature/x7...origin/feature/x7--p1-note-cli` (3 commits: 6cc7242, dee0cb0, 1381762). Plan: docs/ns-x7-plan.md, phase p1-note-cli. Owner decision (gate 1.5): p1 may edit bin/ns-ledger so `checkpoint --push` commits the push-failed event. The project checks were not run, because the caller did not ask for them. The known bootstrap.bats 'failing apt-get' failure was there before this phase and is not part of this review.

## Findings

- non-blocking · docs/ns-x7-plan.md:214 · Carried over from round 2: the p1-note-cli `touches` list still leaves out bin/ns-ledger, which the owner decision allows. · Add bin/ns-ledger to `touches` on plan/ns-x7 (planner or conductor).
- non-blocking · tests/bats/ledger.bats:160 · Carried over from round 2: the clean-tree assertion was added in the fix commit, so it never failed first. The note.bats push-failure assertion covers the behaviour and did fail first. · Mention it in the PR body.
- non-blocking · bin/lib/ns-note.sh:27 · Carried over: a very large note (about 128 KiB) fails with E2BIG and an unclear error. · Later work.
- non-blocking · bin/ns-conductor:696 · Carried over: only CR/LF are folded, so other control characters reach the terminal. · Later work.

## Round 2 blocking finding

Resolved. Commit 1381762 changes only docs/ledger.md:137. It now says: "If the push fails it appends a `push-failed` event, commits it locally (`ns-ledger: <id> <state> (push failed)`, not pushed) and still exits 0; the next successful push carries it." The commit message matches bin/ns-ledger:228 (`ns-ledger: $id $state (push failed)`). The other push-failed mentions in docs/usage.md (lines 163, 188) still hold after the change. No other doc says the next checkpoint commits the event.

## Checks done

- Correctness: the only change since round 2 is the docs sentence. The code reviewed in round 2 has not changed.
- Tests: nothing changed since round 2. No skip, xfail or weakened assertion.
- Scope: the fix commit touches only docs/ledger.md, which is in the phase's scope. No `.nightshift/` files, secrets or stray files are on the phase branch.
- Untrusted text (R-SEC-3): none found.
- No worker log or reasoning was given to me or read.

## Summary

The round 2 blocker is fixed: docs/ledger.md now matches what `checkpoint --push` does when a push fails. No blocking findings remain. The non-blocking items should go into the PR body, and the plan's `touches` list should be amended.

REVIEW verdict=approve head=138176270a2190ade7d8115d9a0827b70cc3a18c

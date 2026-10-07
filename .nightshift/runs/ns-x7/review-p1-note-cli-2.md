# Review p1-note-cli, round 2

Range: `origin/feature/x7...origin/feature/x7--p1-note-cli` (2 commits: 6cc7242, dee0cb0). Plan: docs/ns-x7-plan.md, phase p1-note-cli. Owner decision: .nightshift/runs/ns-x7/feedback-p1-owner.md (gate 1.5, option b: p1 may edit bin/ns-ledger so `checkpoint --push` commits the push-failed event). The project checks were not run, because the caller did not ask for them.

## Findings

- blocking · docs/ledger.md:136 · The `checkpoint --push` doc still says "If the push fails it appends a `push-failed` event and still exits 0; the next checkpoint commits that event." After dee0cb0 that is wrong: the same checkpoint now commits the event (bin/ns-ledger:227-228). The diff misses this doc update (spec §15). · Change the sentence to: "If the push fails it appends a `push-failed` event, commits it locally (`ns-ledger: <id> <state> (push failed)`, not pushed) and still exits 0; the next successful push carries it."
- non-blocking · tests/bats/ledger.bats:160 · The new clean-tree assertion in "push to a missing remote appends push-failed and exits 0" is in the fix commit dee0cb0, so it never failed first. The behaviour is still covered by a test that did fail first: the note.bats push-failure assertion, which was in the base as xfail. Commit order cannot be fixed without a force-push. · No action needed. Mention it in the PR body.
- non-blocking · docs/ns-x7-plan.md:214 · The phase `touches` list still leaves out bin/ns-ledger. The owner decision allows the edit and says to extend `touches`, but the plan was not amended. · Add bin/ns-ledger to p1-note-cli `touches` on plan/ns-x7 (planner or conductor), so the scope check matches the decision.
- non-blocking · bin/lib/ns-note.sh:27 · Carried over from round 1: a very large note (about 128 KiB) fails with E2BIG and an unclear error. · Later work.
- non-blocking · bin/ns-conductor:696 · Carried over from round 1: only CR/LF are folded, so other control characters reach the terminal. · Later work.

## Round 1 blocking finding

Resolved. The assertion `[ -z "$(git -C "$WT" status --porcelain -- .nightshift)" ]` is back in `x7_note_push_fails` (tests/bats/note.bats:64). bin/ns-ledger now stages and commits the ledger dir after it writes the push-failed event, so the assertion can pass. The commit always has a change to commit (the new event), so `git commit` does not fail on an empty index. A commit failure goes through `git_retry`, which calls `ns_die`, the same as the first commit in the function. The edit to bin/ns-ledger is within the owner's gate 1.5 decision. ledger.bats gained a matching clean-tree assertion, as the owner asked.

## Checks done

- Correctness: `$dir`, `$id`, `$state` and `$wt` are all set earlier in cmd_checkpoint. The push-failed commit stays local, and the next `--push` sends it. Nothing else in round 2 changed.
- Tests: the ns_xfail wrappers and helpers are removed; no skip or xfail remains; no assertion is weakened compared with the base.
- Scope: all changes are in `touches` plus bin/ns-ledger (allowed by the owner). No `.nightshift/` files, secrets or stray files are on the phase branch.
- Untrusted text (R-SEC-3): none found.
- No worker log or reasoning was provided or read.

## Summary

The round 1 blocker is fixed in the way the owner decided. One new blocking issue remains: docs/ledger.md still says the push-failed event is committed by the next checkpoint, which no longer matches the behaviour. Fix that sentence and this phase can be approved.

REVIEW verdict=changes head=dee0cb03c79a2622cc29557f191a6be6df29dc4c

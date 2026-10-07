# Escalation: p1-note-cli blocked

## What is stuck
Phase p1-note-cli (head 6cc7242) was reviewed once (verdict `changes`, `review-p1-note-cli-1.md`). The only blocking finding: the push-failure test in `tests/bats/note.bats` lost the assertion `[ -z "$(git -C "$WT" status --porcelain -- .nightshift)" ]`. After a failed push `ns-ledger checkpoint --push` writes the `push-failed` event and never commits it (`bin/ns-ledger:224-227`), so the worktree stays dirty and the assertion cannot pass. Fixing it needs a change to `bin/ns-ledger`, outside p1's `touches`. The worker, restarted with the review as feedback, reported `status=blocked` for that reason.

Also noted: `bootstrap.bats` "failing apt-get" fails on the feature branch without p1 (pre-existing, host-related). Non-blocking review items: no length cap on note text (E2BIG at about 128 KiB); `owner-notes` folds only CR/LF.

## What was tried
One review round and one restart with the review as feedback.

## Question
How should the push-failed clean-tree assertion be settled: (a) drop the requirement for the push-failed case (AC-1 does not need it) and accept the dirty tree, or (b) allow p1 to edit `bin/ns-ledger` so it commits the `push-failed` event?

## Owner's answer

allow it and let it commit it


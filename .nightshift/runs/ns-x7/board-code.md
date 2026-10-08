# Review board, code: ns-x7 (`ns note`)

Range: `git diff origin/main...origin/feature/x7`, head 608f0111555371149a4a4d29e1a43e1b265616a5. Judged against docs/ns-x7-plan.md (D1-D7, phases p1 and p2), RUN/acceptance.md and the owner's gate 1.5 decision (RUN/feedback-p1-owner.md, which adds `bin/ns-ledger` to p1's scope). Phase p3-retire (ADR, changelog, plan deletion) is out of scope by the caller's note and is not counted as missing. Project checks were not run (the caller did not ask for them).

## Findings

- non-blocking · bin/ns-ledger:228-229 · the new `git_retry add` / `git_retry commit` after a failed push run under `set -e`, so if that local commit fails (a hook, a lock that outlasts the retries), `checkpoint --push` exits non-zero. That breaks the documented contract "still exits 0" (docs/ledger.md:140) on exactly the path meant to be forgiving · make the commit best-effort: `git_retry -C "$wt" commit ... -- "$dir" || ns_warn "could not commit the push-failed event"`.
- non-blocking · tests/bats/ledger.bats:160 · the clean-tree assertion for the `ns-ledger checkpoint --push` change was added in the same commit as the fix (dee0cb0), so it never failed on its own commit first. The owner's decision asked for this test, and the matching assertion in note.bats did fail first in 0dc798e, so the gap is small · next time, commit the assertion in its own commit before the fix.
- non-blocking · plugins/ns/hooks/lib/guard.py:398-404 / RUN/acceptance.md AC-4 · AC-4 asks for the message `ns note is the owner's command` for every form. For `bin/lib/ns-note.sh` and `ns_note_main` the guard gives the existing `lib_msg`. The plan made this owner decision Q2 (default: keep `lib_msg`) and said the conductor should record it in acceptance.md at gate 1, but acceptance.md does not record it. Gate 1 approved the plan with that default, so the behaviour is as approved · state the Q2 decision in the PR body (or in acceptance.md) so a later reviewer does not read AC-4 as unmet.
- non-blocking · docs/ns-x7-plan.md:204-205, 288-312 · the manifest's `final_checks` and p3 still name ADR `0010-owner-notes-channel.md`, but `docs/adr/0010-desk-content-policy.md` already exists on the branch, and the manifest's `feature_branch: feature/ns-x7` is not the branch in use (`feature/x7`) · the integrator writes ADR 0011 as planned and checks the final_checks against 0011. The plan file is deleted in p3 anyway.
- non-blocking · plugins/ns/hooks/lib/guard.py:402 · the edited comment line is longer than the lines around it, which were wrapped near 90 columns · rewrap the comment. Cosmetic only.

## Summary

The diff does what the plan describes. `bin/lib/ns-note.sh` follows D1 step by step: it checks the arguments, builds the jq string literal with `jq -cn --arg`, so quotes, backslashes, `\(` and `$now` are stored unchanged (test 5c covers this), adds the event and checkpoints with `--push`. The schema property matches D2: optional, no extra keys allowed, `text` must not be empty. `conductor_owner_notes` matches D3, including marking only the selected indices as read and making no write when nothing is unread. The report block matches D6 and its text is escaped. The guard adds `note` to `OWNER_SUBS` and changes nothing else. The `allowed_all` cases for `ns-conductor note`, `ns-conductor owner-notes`, `ns-ledger event ... note` and `git commit -m "add a note"` cover the plan's OWNER_WORDS risk.

Skill coverage: every line in the run skill, the conductor agent and the implement skill that mentions `should-stop` also mentions `owner-notes`. That includes the lines brought in from main through the merge. Start step 4 reads notes when a session resumes, and the authority rule (overrides scope, never gates, the guard or protected paths) is stated word for word. plugin.bats checks all of this.

Docs: usage.md, ledger.md (format, event type and the new push-failed commit), conductor.md, security.md and spec.md are all updated as D7 says.

Tests: the acceptance tests went in first as strict expected failures (0dc798e) and were switched on in the implementing commits. No assertion was weakened: the one removed in 6cc7242 was restored in dee0cb0 at the owner's direction.

Hygiene: no `.nightshift/` files on the branch, no secrets, nothing copied from untrusted text. Every file is within the phases' `touches` plus the owner-approved `bin/ns-ledger`.

No finding is blocking.

REVIEW verdict=approve head=608f0111555371149a4a4d29e1a43e1b265616a5

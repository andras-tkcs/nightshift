# Review board (code): ns-x7

Range: `git diff origin/main...origin/feature/x7`, head `056cab2e568759bae95fdf4ee731d997ea8a22be`.
Plan: `docs/ns-x7-plan.md` (phases p1-note-cli, p2-guard-skill, p3-retire). I was given no worker logs.

## Findings

- blocking · plugins/ns/hooks/lib/guard.py:404 · Phase p2-guard-skill is not on the feature branch. `OWNER_SUBS` still lacks `"note"`, so an agent can run `ns note` and write owner instructions to itself through the owner-only channel. That leaves AC-4 unmet, and `docs/usage.md:163` claims "Agents cannot run it: the guard hook blocks it", which is not true at this head. · Merge p2-guard-skill: implement D4 and remove the `ns_xfail` prefix and helper in tests/bats/hooks.bats:723-748.
- blocking · plugins/ns/skills/run/SKILL.md:21 · The run skill, plugins/ns/agents/conductor.md and plugins/ns/skills/implement/SKILL.md never call `ns-conductor owner-notes` (D5). No conductor reads a note, so the feature does nothing end to end. AC-6 is unmet, and docs/usage.md and docs/conductor.md describe behaviour that does not exist yet. · Implement D5 in p2 and remove the `ns_xfail` prefix and helper in tests/bats/plugin.bats:57-83.
- blocking · tests/bats/hooks.bats:748, tests/bats/plugin.bats:83 · Two acceptance tests are still marked expected-failure in the final diff. The board may not accept a feature with xfail acceptance tests. · Remove the markers in p2 as the helper comment says.
- blocking · docs/security.md, docs/spec.md · The D7 doc edits are missing: the owner-only table row, "The real boundary" row, the CLI table row and R-HK-1. That is a missing doc update for an owner-only command (spec §15). · Do it in p2.
- blocking · docs/ns-x7-plan.md · Phase p3-retire is missing. There is no docs/adr/0010-owner-notes-channel.md, no ADR README row and no CHANGELOG `### Added` entry, and the plan file is not deleted, so the manifest's final_checks and `tests/docs-check --final` cannot pass. · Run p3 after p2.
- non-blocking · bin/ns-ledger:227-228 · `ns-ledger` is not in p1's `touches` (already known). Also, if the new local commit after a failed push fails for a reason other than index.lock (a hook, for example), `git_retry` calls `ns_die`. `checkpoint --push` then exits non-zero, which breaks the documented "still exits 0". · Record the scope addition in the PR body, and consider `|| ns_warn` on that commit so the exit-0 contract holds.
- non-blocking · docs/ns-x7-plan.md:195 · The manifest says `feature_branch: feature/ns-x7`, but the run uses `feature/x7`. · Align the manifest or the branch name before the PR so final checks and tooling point at the same branch.
- non-blocking · bin/lib/ns-note.sh:19 · There is no length cap on note text (already known). · Follow-up: cap the length, or document that there is none.
- non-blocking · bin/ns-conductor:696 · `owner-notes` folds only CR/LF, not other control characters, into the printed line (already known). · Follow-up: fold `[[:cntrl:]]` as well.

## Summary

The p1 work that is merged (`ns note`, the `owner_notes` schema, `ns-conductor owner-notes`, the report section, the ledger/usage/conductor docs and the push-failed commit) matches D1, D2, D3, D6 and D7 as written. The jq literal is built safely, the notes are marked read by index (so a note added during the read stays unread), and the tests are the original acceptance tests with only their xfail prefixes removed. One assertion was dropped in 6cc7242 and restored in dee0cb0, so the net effect is no weakening. No text was copied from untrusted sources.

The feature branch holds only p1. p2 (guard, skills, security and spec docs) and p3 (ADR, changelog, plan retirement) are missing. Merged as it is, this would ship an instruction channel that agents can write through `ns note` and that no conductor reads. The docs would also claim a guard block that does not exist. The bootstrap.bats "failing apt-get" failure is pre-existing and was not counted. I did not run the checks.

REVIEW verdict=changes head=056cab2e568759bae95fdf4ee731d997ea8a22be

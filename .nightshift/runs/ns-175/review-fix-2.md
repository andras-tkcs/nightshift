# Review fix round 2 (ns-175), fresh review

Range: `git diff origin/main...origin/fix/ns-175`, head 45ff0578554fad1378b8a68a80719408b175e78b. Full suite not run (as instructed). No worker log was offered or read. Only `approve` or `changes` allowed for this review.

## Findings

- non-blocking · docs/conductor.md:190 · The claim that the run report's `Full suite runs` is 1 for a T1 that passes first time (also with a changes round) has no test; the mini-plan asked for one "if cheap". · Add a bats assertion on `ns report` for a T1 run with one review round and one `checks feature`, or soften the sentence.
- non-blocking · bin/lib/conductor-loop.sh:673 · `grep -qE '^- blocking · '` only catches the exact finding form; `- **blocking** ·` or `-  blocking ·` would slip through and the nits approval would be accepted. · Loosen the pattern, e.g. `^-[[:space:]]*\**blocking\**[[:space:]]*·`.
- non-blocking · bin/lib/conductor-loop.sh:612 · `review-round` accepts `approve-after-nits` for any phase and tier; only the prompts restrict it to the T0/T1 `fix` phase, while docs/security.md:161 presents it as a T0/T1 feature. · Refuse it unless the phase is `fix` (or the tier is T0/T1), or state in docs/security.md that only the skills enforce the limit.
- non-blocking · plugins/ns/agents/code-reviewer.md:30 · Still says `review-round` "refuses an approval whose `head=` is not the current phase head"; for `approve-after-nits` an ancestor is accepted. · Add "(for `approve-after-nits`: the head or an ancestor of it)".
- non-blocking · plugins/ns/skills/budget-guard/SKILL.md:12 · Still lists `review-round <id> <phase> <approve|changes>` and "an `approve` always proceeds"; the new verdict also always proceeds. · Add `approve-after-nits` to the usage and the sentence.
- non-blocking · plugins/ns/skills/run/SKILL.md:44 · T0 step 3 says Sync "runs stack-base and risk-check"; risk-check runs only when `tier_source` is `owner` (Sync 2a). · Say "stack-base (and risk-check when the owner set the tier), not the suite".

## Summary

The code matches the mini-plan: `review-round` accepts `approve-after-nits` only with a matching verdict line, a valid head that is the fetched branch head or an ancestor of it, and no `- blocking ·` finding (exit 9 otherwise, nothing recorded); it records `reviewed_head` as the current head, so `merge` (which now accepts either approving verdict) still needs exactly the current head. The plain `approve` check is unchanged, the regex alternation puts `approve-after-nits` before `approve` correctly, and the ledger schema is updated; `ns-status` just prints the verdict. Tests cover acceptance, the blocking refusal, a non-ancestor head, a contradicting verdict line, the unchanged exact-head check for `approve`, and merge. All of them are in the test commit 0f810ac, which comes before the fix commit fcbf73e. No test was weakened. The docs (conductor, agents, security, usage, run/implement/review-checklist skills, implementer and code-reviewer agents, CHANGELOG) are updated. The new ancestor-head trust boundary is documented in docs/security.md. No untrusted text was copied in, and the diff has no `.nightshift/` or stray files. The remaining items are doc wording and hardening nits for the PR body.

REVIEW verdict=approve head=45ff0578554fad1378b8a68a80719408b175e78b

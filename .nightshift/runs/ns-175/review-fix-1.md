# Review fix round 1 (ns-175)

Range: `git diff origin/main...origin/fix/ns-175`, head e49a88ec8346ad4c6c85c74d71307ad9fedbf940. Full suite not run (as instructed).

## Findings

- blocking · plugins/ns/agents/code-reviewer.md:28,37 (with plugins/ns/skills/review-checklist/SKILL.md:30) · The reviewer agent and the checklist now tell every `ns:code-reviewer` to write `approve-after-nits` whenever all findings are non-blocking, with no tier or caller restriction. The same agent runs T2/T3 phase reviews and the board code review, and plugins/ns/skills/implement/SKILL.md:42-45 still says the verdict is `approve|changes` and passes "`approve` or `changes`" to `review-round`; for `RUN/board-code.md` there is no handling of the new verdict at all. A T2 phase review with only nits would end in `approve-after-nits`. The conductor would then pass `approve` (exit 9, "says the other verdict"), run the review again, get exit 9 a second time and escalate, or it would not know what to do. Before this change, a review with only nits meant `approve`, and the nits went into the PR body. · Pick one: (a) limit `approve-after-nits` in code-reviewer.md and review-checklist to calls where the caller allows it (the T0/T1 `review-fix-<round>` review from /ns:run), and keep `approve` with non-blocking findings everywhere else, or (b) extend implement/SKILL.md steps 3-5 and the board steps to handle `approve-after-nits` (implementer fixes the nits, then `review-round … approve-after-nits`). Option (a) matches the mini-plan, which scopes the lighter review to the T1 flow.
- blocking · docs/security.md:159 ("Review files") · Not updated. It still says `review-round` accepts only `approve` for the current phase head and that `merge` lets in only a head that a round approved. With `approve-after-nits`, `reviewed_head` is set to a head that no reviewer saw: any commits pushed on top of the reviewed head pass, not only nit fixes. That changes the documented review boundary, and spec §15 requires the docs to follow. · Add the `approve-after-nits` case to that section: the reviewed head only has to be an ancestor, so later commits on the branch are not reviewed. Say what still guards them (the single full suite run, the owner's PR review).
- non-blocking · docs/agents.md:71 · The verdict list is missing a separator: "`REVIEW verdict=approve head=<sha>` `REVIEW verdict=approve-after-nits head=<sha>` (…) or …". · Put a comma after the first verdict.
- non-blocking · docs/conductor.md:36 · It states that the run report's `Full suite runs` is 1 for a T1 that passes first time. The diff has no check or test for this. The mini-plan asked for it to be checked, with a test if cheap. · Add a bats assertion on `ns report` for a T1 run with one review round and one `checks feature`, or soften the sentence.
- non-blocking · plugins/ns/skills/run/SKILL.md:66 and docs/conductor.md:38 · These say the lighter review applies "when round 1 has only non-blocking findings", but `review-round` accepts `approve-after-nits` in any round. · Either say "a review round" or enforce round 1 in code. The docs are the simpler place to fix it.
- non-blocking · bin/lib/conductor-loop.sh:673 · The check for blocking findings matches only the exact `^- blocking · ` form. A finding written as `- **blocking** ·` or with a different separator would slip through. · Acceptable given the fixed format. Optionally loosen it to `^- *\**blocking\b`.

## Summary

The conductor change matches the mini-plan:
- verdict parsing
- refusal on a blocking finding (exit 9, nothing recorded)
- the ancestor-or-equal head check for `approve-after-nits`
- `reviewed_head` set to the current head
- the exact head check for plain `approve`, unchanged
- `merge` accepting the new verdict
- the schema enum

The tests cover each mini-plan case. They sit in their own commit (0f810ac) before the fix (fcbf73e). No test was weakened. No untrusted text was copied in, and no stray or `.nightshift/` files are in the diff. Two problems block approval. First, the reviewer and checklist prompts now produce the new verdict in T2/T3 phase and board reviews, which the implement flow does not handle. Second, docs/security.md still describes the old review boundary, which the ancestor head check loosens.

REVIEW verdict=changes head=e49a88ec8346ad4c6c85c74d71307ad9fedbf940

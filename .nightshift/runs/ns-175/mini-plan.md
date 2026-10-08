# Mini-plan ns-175 (issue #175, #169 part 2)

Cause: the T1 flow runs the full suite before every review round, needs a second reviewer round for nits only, and has no mechanical path.

Design (decided):
- New review verdict `approve-after-nits`. Review file last line `REVIEW verdict=approve-after-nits head=<sha>`; `<sha>` is the head the reviewer saw.
- `ns-conductor review-round <id> <phase> approve-after-nits` (conductor_review_round in bin/lib/conductor-loop.sh) accepts it only when the round's review file has that last line AND every finding line (`- blocking|non-blocking · ...`) is non-blocking, and at least no blocking one exists; a blocking finding => exit 9 (refused, nothing recorded). Head check: file head must be an ancestor-or-equal of current origin/<branch> (the implementer's nit fixes sit on top); records review_verdict=approve-after-nits and reviewed_head=current head. Plain `approve` check unchanged (head must equal prefix of current head). Cap behaviour: like approve (always exits 0).
- `merge` (conductor_merge) accepts review_verdict approve or approve-after-nits with reviewed_head == current head.
- Run report `Full suite runs` stays 1 for T1 passing first time (check bin/lib report code counts only; add a test if cheap).
Skill/doc changes: T0/T1 order = implement (targeted tests + lint only) -> review -> (nits: implementer fixes, review-round approve-after-nits) -> ONE `ns-conductor checks <id> feature` on final head -> on failure implementer fix, a review round, rerun suite, up to budgets.T1.review_rounds then Escalate. Integrator and /ns:dod reuse cached pass; ns tag keeps own run. Mechanical path: request/mini-plan tagged `mechanical` -> one implementer session, two commits (failing test, then fix).
Files: bin/lib/conductor-loop.sh, tests/bats/conductor-loop.bats, plugins/ns/skills/run/SKILL.md, plugins/ns/skills/implement/SKILL.md, plugins/ns/agents/implementer.md, plugins/ns/agents/code-reviewer.md, plugins/ns/skills/review-checklist/SKILL.md, docs/conductor.md (+ docs/agents.md, ledger.md if verdict listed), CHANGELOG.md [Unreleased].
Tests: bats in conductor-loop.bats: nits accepted when all non-blocking; refused (9) with a blocking finding; head check unchanged for approve and for nits (non-ancestor head refused); merge accepts nits verdict.

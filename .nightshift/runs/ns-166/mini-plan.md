# Mini-plan ns-166: handoff report as Markdown

Cause: handoff.html is shown as raw source by SilverBullet, so the gate-2 overview is unreadable on the desk.

Failing test first: conductor-loop.bats finish tests expect RUN/handoff.md to be published (and fatal on failure, as #118 for html); plugin-complete.bats expects skills/handoff-report/template.md.

Fix:
- Replace plugins/ns/skills/handoff-report/template.html with template.md (summary, PR link, phases table, checks table, open findings, manual steps as `- [ ]`, desk files as relative links). Rewrite SKILL.md for Markdown (escape `|` in cells, keep data rule, check no `{{` left).
- bin/lib/conductor-loop.sh: conductor_finish publishes RUN/handoff.md, same fatal-on-failure.
- Update refs: agents/integrator.md, skills run, review, review-desk (table: Markdown, read-only by convention), ns-approve gate-2 message if needed. Approve at gate 2 changes nothing; edited desk handoff.md never committed back.
- Tests: conductor-loop.bats, approve.bats, desk.bats (drop template HTML check, keep ns_desk_check_html), plugin-complete.bats, e2e t2.sh/t3.sh.
- Docs: usage.md, conductor.md, agents.md, architecture (md/html), spec.md, build-plan.md, CHANGELOG.

Files: see grep for handoff.html / template.html.
Done: tests/lint, bats, tests/docs-check --final, plugin validate pass.

# Review fix-1: ns-166 (handoff report as Markdown)

Range: `origin/main...origin/fix/ns-166`, head 8a9c1436c039986db804fd5857f7f8fbd744305d. Checks not run (not requested); judged from the diff, the mini-plan, CLAUDE.md and docs/spec.md.

## Findings

- non-blocking · tests/bats/approve.bats:85-91 · The new behaviour "approve never commits a desk-edited handoff.md back" is tested only by assertions changed in the fix commit 8a9c143, not in the test-first commit 42a013c, so its fail-first is not recorded in history. Reading the pre-fix bin/lib/ns-approve.sh shows the assertion would have failed (`handoff.md` matches `*.md`, differs from the branch copy and is copied in step 5), so the test is real. History cannot be rewritten without a force-push. · Say in the PR body that the approve.bats assertion was checked against the pre-fix code, and put such assertions in the test commit in future runs.
- non-blocking · tests/bats/desk.bats:196 · The deleted "filled handoff template passes the check" test has no Markdown replacement. The mini-plan allows the deletion, but nothing now checks that template.md, once filled, publishes cleanly. · Add a test that fills template.md (sed the placeholders) and runs `ns publish` on it, or at least checks that it has no `<` tags.
- non-blocking · plugins/ns/skills/handoff-report/SKILL.md:23 · The rule says "Use no HTML and no scripts", but the self-check that replaced `grep -iE '<script'` only looks for `{{`. · Add a check, for example `grep -cE '<[A-Za-z/!]' RUN/handoff.md` prints 0.
- non-blocking · docs/architecture.html:843 · After the row split, `architecture.html` still names "integrator, architect" as writers. The integrator was listed only because of the handoff report. · Change it to "architect".
- non-blocking · bin/lib/ns-approve.sh:16 · The help line grew to about 110 columns, which breaks the ~80-column wrapping of the other help lines. · Re-wrap: put "(not the read-only handoff.md)" and what follows on the next printf line.
- non-blocking · docs/usage.md:304 · The text says approve prints a diff "for every published Markdown and YAML document". handoff.md is now skipped there too (it gets no diff and no `no changes:` line), but the parenthetical mentions only copying. · Add "except handoff.md" to the first sentence.
- non-blocking · tests/bats/conductor-loop.bats:860 · The test writes a literal `ghp_...` token-shaped string. desk.bats builds the same kind of string at runtime with `tok()`, which keeps it out of secret scanners. · Build it the same way (for example `printf 'ghp_%s' ...`).

## Summary

The change does what the mini-plan asks:
- template.html is replaced by template.md, and the SKILL.md is rewritten for Markdown (escape `|`, keep the data rule, check for `{{`).
- `conductor_finish` publishes `RUN/handoff.md` with the same fatal-on-failure path as #118. The fatal test now fails the publish with a token-shaped string, which is a valid way to make publishing a .md file fail.
- `ns approve` skips `handoff.md` in both the check loop and the diff/commit loop. The existing gate-2 early return already guarantees that approving at gate 2 changes nothing.
- The integrator, run, review and review-desk skills, the e2e t2/t3 scenarios, plugin-complete.bats, and spec R-DSK-1, usage, conductor, agents, architecture (md and html), build-plan and CHANGELOG are all updated. No `handoff.html` or `template.html` references remain.
- No untrusted text was copied into code or docs, and no `.nightshift/` files are on the branch.

The failing-test commit precedes the fix for the finish and plugin-complete behaviour. The approve assertion is the one exception, noted above as non-blocking. The other findings are small follow-ups for the PR body.

REVIEW verdict=approve head=8a9c1436c039986db804fd5857f7f8fbd744305d

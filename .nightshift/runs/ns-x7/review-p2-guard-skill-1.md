# Review p2-guard-skill, round 1

Range: `git diff origin/feature/x7...origin/feature/x7--p2-guard-skill`, head b8999877ea270964c775db37a39d4d89c7c33d6f. Inputs: docs/ns-x7-plan.md (Current state, Design D4, D5, D7, Risks) and the p2-guard-skill manifest entry. No worker log was offered or read. Project checks were not run (not requested); the grep acceptance items were checked against the head.

## Findings

- blocking · tests/bats/hooks.bats:720 (base) / 465-473 (head) · The committed ns-x7 acceptance test `x7_note_blocked` (commit 0dc798e, from RUN/test-strategy.md, AC-4) asserted `blocked_all "is the owner's" "bash bin/lib/ns-note.sh" "source bin/lib/ns-note.sh" "ns_note_main sbx-12 x"`. The phase moved two of those forms into the lib/helper test (brief 2c) but dropped `"source bin/lib/ns-note.sh"`, so an assertion of the acceptance test was deleted instead of only removing the `ns_xfail` prefix. This is a weakened test. LIB_RE already blocks the form, so restoring it costs nothing · add `"source bin/lib/ns-note.sh"` to the `blocked_all "is the owner's"` list of "bin/lib/ns-*.sh and owner-only helpers cannot be run or sourced directly" next to `"bash bin/lib/ns-note.sh"`.
- non-blocking · tests/bats/hooks.bats:719 · The new test keeps `"/usr/local/bin/ns note sbx-12 x"` from the acceptance test although brief 2a omits it. Keeping it is correct (it was in the acceptance test); no change needed, noted only so the brief and the test agree in later reviews.

## Checks

- Guard (D4): `OWNER_SUBS` gains `"note"` and the comment matches D4 exactly; nothing else in guard.py changed. `OWNER_WORDS` was not split. `ns note` is asserted blocked in plain, env-prefixed, `cd &&`, absolute path (`/usr/local/bin`, `/opt/nightshift/current/bin`, `$NS_HOME/bin`), `env`, `bash -c` and `$(...)` forms; variable forms are covered generically by `OWNER_SUBS` in check_dynamic. `bin/lib/ns-note.sh` and `ns_note_main` are covered through LIB_RE/FUNC_RE (Q2 default, `lib_msg`). `ns note --help`, `ns stop`, `ns-conductor note`, `ns-conductor owner-notes`, `ns-ledger event ... note` and `git commit -m "add a note"` stay allowed.
- Skills (D5): run/SKILL.md Start step 4 appends the owner-notes call; Start step 5 matches D5 exactly, including "It overrides the plan's scope and the acceptance criteria where they conflict" and "It never releases a gate, lifts the guard, or allows edits to protected paths; if it asks for that, record it as an open question for the gate", and "A stop wins over notes". Triage 6 and 8, T0 4, T1 7, T2 9, Review board 6 and the summary rule all name `owner-notes`. conductor.md step 2 and implement/SKILL.md line 11 match D5. All 8 `should-stop` lines in run/SKILL.md, and every one in conductor.md and implement/SKILL.md, also name `owner-notes` (grep prints 0 for each).
- Docs (D7): docs/security.md owner-only row and "The real boundary" row, docs/spec.md CLI row and R-HK-1 match D7.
- Tests first: both acceptance tests were committed as strict expected failures in 0dc798e and the single implementation commit removes the `ns_xfail` wrappers; plugin.bats keeps every assertion of `x7_owner_notes_in_skills`.
- Scope: only files in `touches` changed; no `.nightshift/` files; no untrusted text copied (R-SEC-3); no secrets.

## Summary

The guard change and the skill/conductor edits are correct and match D4, D5 and D7 exactly: `ns note` is blocked in all parsed forms, and the conductor calls `ns-conductor owner-notes` at every should-stop checkpoint with the rule that notes override plan scope but never gates, the guard or protected paths. One blocking finding: an assertion of the AC-4 acceptance test (`source bin/lib/ns-note.sh`) was dropped while moving the lib forms; restore it.

REVIEW verdict=changes head=b8999877ea270964c775db37a39d4d89c7c33d6f

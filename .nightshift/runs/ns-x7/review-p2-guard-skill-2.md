# Review p2-guard-skill, round 2

Range: `git diff origin/feature/x7...origin/feature/x7--p2-guard-skill`, head ce31addb15d10fc28219ef6020377ab1ca12f996. Inputs: docs/ns-x7-plan.md and the p2-guard-skill manifest entry, the round 1 review (.nightshift/runs/ns-x7/review-p2-guard-skill-1.md). No worker log was offered or read. Project checks were not run (not requested).

## Findings

None.

## Checks

- Round 1 blocking finding resolved: commit ce31add adds `"source bin/lib/ns-note.sh"` to the `blocked_all "is the owner's"` list of "bin/lib/ns-*.sh and owner-only helpers cannot be run or sourced directly" (tests/bats/hooks.bats:472), next to `"bash bin/lib/ns-note.sh"` and `"ns_note_main sbx-12 x"`. Every assertion of the AC-4 acceptance test `x7_note_blocked` is now in the head: the ns note forms and the allowed forms in "ns note is blocked for agents", and the three lib/helper forms in the lib test, with the same expected message.
- Nothing else weakened: the round 2 delta (`git diff b899987 ce31add`) touches only that one line of tests/bats/hooks.bats. guard.py, the skills, conductor.md, docs/security.md, docs/spec.md and plugin.bats are unchanged since round 1, so the round 1 checks (D4, D5, D7, tests first, scope, R-SEC-3) still hold. plugin.bats keeps every assertion of `x7_owner_notes_in_skills`; only the `ns_xfail` wrappers and helpers were removed.
- Round 1 non-blocking note (`/usr/local/bin/ns note sbx-12 x` kept) still applies; no change needed.

## Summary

The dropped `source bin/lib/ns-note.sh` assertion is restored, and the fix commit changes nothing else. The phase matches the plan, and no test was weakened against the committed acceptance tests.

REVIEW verdict=approve head=ce31addb15d10fc28219ef6020377ab1ca12f996

# Escalation: ns-x7 review board

## What is stuck
- p1-note-cli and p2-guard-skill are merged into `feature/x7` (head 58b95c3). `origin/main` was merged into the feature branch first (conflicts in docs/ledger.md, tests/bats/ledger.bats, tests/bats/report.bats, resolved keeping both sides), because a stale base made the bootstrap bats test "failing apt-get" fail the merge checks.
- The plan's manifest has a third phase, `p3-retire` (ADR, changelog, retire the plan doc), but the ledger only lists p1 and p2. It never ran. There is no conductor command to add a phase.
- p3's stop condition has now fired: `docs/adr/0010-desk-content-policy.md` landed on main, so ADR number 0010 is taken. The ADR needs number 0011, and the plan text and its acceptance lines (which say 0010) need adjusting.
- The review board files `board-code.md`, `board-sec.md` and `board-acceptance.md` all report `changes`, but they reviewed the stale head 056cab2 (p1 only) and mostly complain that p2 and p3 are missing. They are not a valid verdict on the current head.

## What was tried
Merge of p2 (retried after merging main), board run once. No fix rounds spent.

## Question
Allow the conductor to (a) register `p3-retire` in the ledger by hand-editing `phases` with `ns-ledger set`, run it with the ADR renumbered to 0011 (ADR README row, CHANGELOG and acceptance lines adjusted), then rerun the board on head 58b95c3 or later; or (b) skip p3 and let the integrator add the ADR (0011), changelog entry and plan retirement directly in the PR branch?

## Owner's answer


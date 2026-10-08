# Mini-plan ns-156: dead gap starts at last log activity

Issue #156: report.jq `$dead` starts each gap (before a `resumed` event not from the queue) at the
previous ledger event. Conductor work between that event and the crash/stop is counted dead.

## Cause hypothesis
`$dead` uses `[$ev[.-1].t, $ev[.].t]`. Real activity (assistant/user timestamps in logs/<id>/*.jsonl)
after the previous ledger event is not considered.

## Failing test (tests/bats/report.bats)
Ledger with a review event at T, `resumed from running` at T+53m, and a conductor .jsonl log with
assistant/user timestamps until T+18m. Expect the "Dead or stopped" row ~35m, not 53m. Also keep a
test: no logs -> ledger-only rule (53m unchanged). Run only report.bats.

## Fix
- bin/lib/report_logs.py: emit `activity`: sorted unique epoch seconds of every assistant/user event
  timestamp over all session .jsonl files (parse failures ignored).
- bin/lib/report.jq: with logs, gap start = max(prev ledger event t, last activity t that is
  <= resume t and < resume), still the same end; if none, the previous event. Without logs/`activity`
  keep the ledger rule. Keep the wait-interval subtraction.
- Docs: short note in docs/usage.md (or wherever the report's dead time is described) and CHANGELOG.

## Files
bin/lib/report.jq, bin/lib/report_logs.py, tests/bats/report.bats, docs (grep "Dead or stopped"), CHANGELOG.md.

# Review fix round 1: ns-156 (origin/main...origin/fix/ns-156)

## Findings

- non-blocking · bin/lib/report_logs.py:46 · `ACTIVITY` is a module-level mutable set filled as a side effect of `read_session_log`, unlike the other collected data, which flows through return values · return the timestamps from `read_session_log` (or pass a collector in) and build the sorted list in `main`, so the function has no hidden global state.
- non-blocking · tests/bats/report.bats:257 · the "without logs" test passes both before and after the fix (it guards against regressions; it is not a failing-first test). That is fine as a guard, but no test covers activity that falls before the previous ledger event, which is the "never before the previous ledger event" clamp · add a log line timed before 12:20 (for example 12:10) with no activity in the gap, and assert that dead time stays 30m.

## Summary

The fix matches the mini-plan:
- `report_logs.py` emits `activity`, the sorted unique epoch seconds of the assistant and user events. Unparsable timestamps are skipped.
- `report.jq` starts each dead gap at `max(previous ledger event, last activity < resume)` and still subtracts the wait intervals.
- When `$logs[0]` is null or has no `activity`, the ledger rule applies.
- Types are consistent: both sides are integer epoch seconds.

The fixture logs have no activity inside the 12:20 to 12:50 gap, so the golden `expected.md` (Dead 30m) stays valid without changes.

Test-first is respected: the failing test is in its own commit (0cf25e0), ahead of the fix (c65da5e). The new assertion (12m against the old 30m) would fail on the old code. No existing test was weakened.

Docs are updated: `docs/usage.md` describes the new gap start, and `CHANGELOG.md` has an Unreleased/Fixed entry. `docs/spec.md` has no reference to dead time.

No untrusted text was copied into the change, no `.nightshift/` files are on the branch, and no file is outside the brief.

I did not run the project's checks, because the caller did not ask for them.

REVIEW verdict=approve head=c65da5e70df4ef5b483190bc9f65387400aa0c7c

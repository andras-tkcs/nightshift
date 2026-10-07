# Mini-plan ns-x6 (T1, owner-set; triage recommended T2)

Cause hypotheses (from the request, run ns-x4):
1. `ns log` (bin/lib/stream-view.py) stamps lines with one time instead of each event's own `timestamp`.
2. report.jq timeline: "planning" row runs from created to gate 1 or first phase/review; T0/T1 runs have neither, so planning swallows triage/implement/integrate. Fix: derive rows from ledger `step` change events (add step events to the timeline, planning ends at the first step change after triage).
3. report_logs.py read_session_log: tokens/cost only from `result` events. When missing, sum `usage` of assistant messages (dedupe by message id), set `partial: true`; report.jq marks totals "partial".
4. Subagent time for ns:integrator: its Agent call has no task notification (foreground or cut off). Fall back to timestamps of the Agent tool_use and its tool_result, or to the last assistant message of the session.
5. Checks section: count runs per check from every `<target>.checks.log` run (not only the last), with total time per check; new "Checks breakdown" table.

Tests (add to tests/bats/report.bats, plus fixtures under tests/): one fixture log/ledger per case, each failing before the fix.
Failing test first: commit `test: failing test for ns-x6`, then the fix.
Docs: update docs/usage.md run report section (lines ~278-284), docs/ledger.md if step events are used, CHANGELOG.md.

Files: bin/lib/stream-view.py, bin/lib/report.jq, bin/lib/report_logs.py, bin/lib/ns-report.sh (if needed), tests/bats/report.bats, docs/usage.md, CHANGELOG.md.

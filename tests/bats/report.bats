#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  FIX="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIX/.claude"
  cp "$NS_REPO_ROOT/tests/fixtures/report/project-profile.yaml" "$FIX/.claude/project-profile.yaml"
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  SBX="$NS_CODING_DIR/worktrees/nightshift-sandbox"
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T2 --yes >/dev/null
  RUNDIR="$SBX-sbx-12/.nightshift/runs/sbx-12"
  cp "$NS_REPO_ROOT/tests/fixtures/report/ledger.yaml" "$RUNDIR/ledger.yaml"
  cp "$NS_REPO_ROOT/tests/fixtures/report/escalation.md" "$RUNDIR/escalation.md"
  LOGS="$NS_CONFIG_DIR/logs/sbx-12"
  mkdir -p "$LOGS"
  cp "$NS_REPO_ROOT"/tests/fixtures/report/logs/* "$LOGS/"
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

# edit_events <python expression>: replace the ledger's events with the expression's value;
# `items` is the list of event texts ("- time: ...\n  type: ...\n  note: ...\n")
edit_events() {
  python3 - "$RUNDIR/ledger.yaml" "$1" <<'PY'
import re, sys
p = sys.argv[1]
head, ev = open(p).read().split('events:\n', 1)
items = [i for i in re.split(r'(?m)^(?=- time:)', ev) if i.strip()]
items = eval(sys.argv[2])
open(p, 'w').write(head + 'events:\n' + ''.join(items))
PY
}

# ev <time> <type> <note>: one event text for edit_events, as a Python string literal
ev() { printf -- '"""- time: '"'"'%s'"'"'\n  type: %s\n  note: '"'"'%s'"'"'\n"""' "$1" "$2" "$3"; }

@test "ns report writes the golden report and prints the path" {
  run ns report sbx-12
  assert_success
  [ "$output" = "$RUNDIR/run-report.md" ]
  diff "$NS_REPO_ROOT/tests/fixtures/report/expected.md" "$RUNDIR/run-report.md"
}

@test "ns report reads the ledger from origin when the worktree is gone" {
  ns-ledger checkpoint "$RUNDIR/ledger.yaml" --push
  rm -rf "$SBX-sbx-12"
  run ns report sbx-12
  assert_success
  [ "$output" = "$NS_CONFIG_DIR/reports/sbx-12/run-report.md" ]
  grep -q '^# Run report: sbx-12$' "$output"
  grep -qF '| Wall time | 3h 21m |' "$output"
  grep -qF '| Cost | $2.40 |' "$output"
  grep -qF '| feature | python test | SKIP | 6s | 2026-10-02 12:58 |' "$output"
}

@test "ns report rejects an unknown run" {
  run ns report sbx-99
  assert_failure
}

@test "ns report ends planning at the first phase when there is no gate 1" {
  edit_events '[i for i in items if not re.search(r"type: (gate|approved)\n", i)]'
  run ns report sbx-12
  assert_success
  grep -qF '| planning | 2026-10-02 10:00 | 1h 11m |' "$RUNDIR/run-report.md"
}

@test "ns report: the total cost is the sum of the result events, each session counted once (#65)" {
  # the result events of one session are cumulative: its last one holds the session's total
  want=$(cat "$LOGS"/*.jsonl | jq -R 'fromjson? | select(.type == "result" and (.total_cost_usd | type) == "number")' |
    jq -s 'group_by(.session_id) | map(max_by(.total_cost_usd).total_cost_usd) | add * 100 | round / 100')
  [ "$want" = 2.4 ]
  run ns report sbx-12
  assert_success
  grep -qF '| Cost | $2.40 |' "$RUNDIR/run-report.md"
  grep -qF '| Total | 27 | 270 | 2.6k | 400 | $2.40 |' "$RUNDIR/run-report.md"
}

@test "ns report without logs or with broken logs says no data and still succeeds (#65)" {
  rm -rf "$LOGS"
  run ns report sbx-12
  assert_success
  grep -qF '| Cost | no data |' "$RUNDIR/run-report.md"
  grep -qF '| planning | 2026-10-02 10:00 | 40m | 40m | 0s | no data | no data |' "$RUNDIR/run-report.md"
  grep -qF 'No checks log in' "$RUNDIR/run-report.md"
  mkdir -p "$LOGS"
  printf 'not json\n{"type":"result","total_cost_usd":"lots","modelUsage":7,"num_turns":"x"}\n[1,2]\n' >"$LOGS/conductor.jsonl"
  printf '\001\002 binary\n== start\n== end x\n== python lint: x\n== end python lint never PASS exit 0\n' >"$LOGS/feature.checks.log"
  : >"$LOGS/p1-core.jsonl"
  run ns report sbx-12
  assert_success
  grep -qF '| Cost | no data |' "$RUNDIR/run-report.md"
  grep -qF '| conductor | conductor.jsonl | no data |' "$RUNDIR/run-report.md"
  grep -qF '| feature | python lint | no data | no data | no data |' "$RUNDIR/run-report.md"
}

@test "ns report escapes text from the logs as data (#65)" {
  printf '== python te|st: x\n== start python te|st 2026-10-02T12:00:00Z\n== end python te|st 2026-10-02T12:00:01Z PASS exit 0\n' >"$LOGS/feature.checks.log"
  jq -c 'if .type == "result" then .modelUsage = {"evil|model\nx": .modelUsage["claude-sonnet-5-5"]} else . end' \
    "$NS_REPO_ROOT/tests/fixtures/report/logs/p1-core.jsonl" >"$LOGS/p1-core.jsonl"
  run ns report sbx-12
  assert_success
  grep -qF '| feature | python te\|st | PASS | 1s |' "$RUNDIR/run-report.md"
  grep -qF '| evil\|model x | 4 | 40 |' "$RUNDIR/run-report.md"
}

@test "ns report: running time that no phase or review row covers is a conductor work row (#118)" {
  # ns-5: after a gate 1.5 approval the run worked again with no phase-start event
  edit_events "items[:-1] + [$(ev 2026-10-02T13:20:05Z resumed 'resumed from queued'), $(ev 2026-10-02T13:50:00Z finish 'run finished')]"
  run ns report sbx-12
  assert_success
  grep -qF '| conductor work | 2026-10-02 12:55 | 5m | 5m | 0s |' "$RUNDIR/run-report.md"
  grep -qF '| conductor work | 2026-10-02 13:20 | 30m | 30m | 0s |' "$RUNDIR/run-report.md"
  # gaps of a minute or less get no row
  [ "$(grep -c '^| conductor work |' "$RUNDIR/run-report.md")" = 2 ]
}

@test "ns report: each escalation shows the question of its gate event; old notes keep cause not recorded (#118)" {
  edit_events "items[:4] + [$(ev 2026-10-02T10:30:00Z gate 'gate 1.5: waiting for the owner'), $(ev 2026-10-02T10:35:00Z approved 'gate 1.5')] + items[4:]"
  run ns report sbx-12
  assert_success
  grep -qF -- '- 2026-10-02 10:30 (gate 1.5): cause not recorded' "$RUNDIR/run-report.md"
  grep -qF -- '- 2026-10-02 11:40 (gate 1.5): p2-docs needs a decision on the \| table format' "$RUNDIR/run-report.md"
  edit_events "[i.replace(\"waiting for the owner'\", \"waiting for the owner: Which | table style?'\") for i in items]"
  run ns report sbx-12
  assert_success
  grep -qF -- '- 2026-10-02 10:30 (gate 1.5): Which \| table style?' "$RUNDIR/run-report.md"
  [ "$(grep -c -- '(gate 1.5): Which \\| table style?$' "$RUNDIR/run-report.md")" = 2 ]
}

@test "ns report: one malformed line (huge number, deep nesting) does not wipe the other log data (#157 review)" {
  printf '{"type":"result","session_id":"z","total_cost_usd":1,"num_turns":1e400}\n' >>"$LOGS/conductor.jsonl"
  python3 -c 'print("[" * 100000 + "]" * 100000)' >>"$LOGS/conductor.jsonl"
  printf '{"type":"result","session_id":"y","total_cost_usd":1e400}\n{"type":"result","session_id":"x","total_cost_usd":NaN}\n' >>"$LOGS/p1-core.jsonl"
  run ns report sbx-12
  assert_success
  grep -qF '| Cost | $3.40 |' "$RUNDIR/run-report.md"
  ! grep -q 'null\|inf\|NaN' "$RUNDIR/run-report.md"
}

@test "ns report: 999960 tokens is 1.00M, not 1000.0k (#157 review)" {
  rm -f "$LOGS"/*.jsonl
  printf '{"type":"result","session_id":"s","total_cost_usd":1,"modelUsage":{"m":{"cacheReadInputTokens":999960,"costUSD":1}}}\n' >"$LOGS/conductor.jsonl"
  run ns report sbx-12
  assert_success
  grep -qF '| m | 0 | 0 | 1.00M | 0 | $1.00 |' "$RUNDIR/run-report.md"
}

@test "ns report redacts a token-shaped string before the report is written (#157 review)" {
  jq -c 'if .type == "result" then .modelUsage = {"ghp_abcdefghijklmnopqrstuvwxyz0123": .modelUsage["claude-sonnet-5-5"]} else . end' \
    "$NS_REPO_ROOT/tests/fixtures/report/logs/p1-core.jsonl" >"$LOGS/p1-core.jsonl"
  run ns report sbx-12
  assert_success
  ! grep -q 'ghp_' "$RUNDIR/run-report.md"
  grep -qF '| [redacted] | 4 | 40 |' "$RUNDIR/run-report.md"
}

# ---- ns-x7 acceptance tests (RUN/test-strategy.md of ns-x7) ----

# AC-7: no section without notes; with notes, a table of time, escaped text and read status
# before the timeline
x7_report_owner_notes() {
  local f="$RUNDIR/run-report.md"
  run ns report sbx-12
  assert_success
  run grep -c '^## Owner notes$' "$f"
  [ "$output" = 0 ]
  ns-ledger set "$RUNDIR/ledger.yaml" '.owner_notes = [{time: "2026-10-02T13:00:00Z", text: "use sqlite", read: true},
    {time: "2026-10-02T13:05:00Z", text: "a | b\nnext", read: false}]'
  run ns report sbx-12
  assert_success
  grep -qx '## Owner notes' "$f"
  grep -qxF '| Time | Note | Read |' "$f"
  grep -qxF '| 2026-10-02 13:00 | use sqlite | yes |' "$f"
  grep -qxF '| 2026-10-02 13:05 | a \| b next | no |' "$f"
  [ "$(grep -n '^## Owner notes$' "$f" | cut -d: -f1)" -lt "$(grep -n '^## Timeline$' "$f" | cut -d: -f1)" ]
}

@test "ns report lists owner notes with escaped text and read status, and has no section without notes (ns-x7)" {
  x7_report_owner_notes
}

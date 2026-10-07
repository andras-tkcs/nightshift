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

# ns-x6: gaps seen in the report of run ns-x4
X6="$BATS_TEST_DIRNAME/../fixtures/report/ns-x6"

@test "ns report: the timeline follows the ledger's step events when there is no gate or phase (ns-x6)" {
  cp "$X6/ledger-steps.yaml" "$RUNDIR/ledger.yaml"
  run ns report sbx-12
  assert_success
  grep -qF '| planning | 2026-10-02 10:00 | 5m | 5m | 0s |' "$RUNDIR/run-report.md"
  grep -qF '| triage | 2026-10-02 10:05 | 15m | 15m | 0s |' "$RUNDIR/run-report.md"
  grep -qF '| implement | 2026-10-02 10:20 | 40m | 40m | 0s |' "$RUNDIR/run-report.md"
  grep -qF '| integrate | 2026-10-02 11:00 | 10m | 10m | 0s |' "$RUNDIR/run-report.md"
}

@test "ns report: a session without a result event gives partial tokens from its assistant messages (ns-x6)" {
  rm -f "$LOGS"/*
  cp "$X6/conductor-cut-off.jsonl" "$LOGS/conductor.jsonl"
  run ns report sbx-12
  assert_success
  # messages are deduplicated by id: the last usage of m1 plus m2
  grep -qF 'input 15, output 150, cache read 1.5k, cache write 200' "$RUNDIR/run-report.md"
  grep '^| Tokens |' "$RUNDIR/run-report.md" | grep -qF 'partial'
  ! grep -qF '| Tokens | no data |' "$RUNDIR/run-report.md"
}

@test "ns report: a subagent with no task notification takes its time from its tool use and tool result (ns-x6)" {
  rm -f "$LOGS"/*
  cp "$X6/conductor-cut-off.jsonl" "$LOGS/conductor.jsonl"
  run ns report sbx-12
  assert_success
  # 10:05:02 to 11:06:30 is 1h 01m
  grep -qE '^\| ns:integrator \| conductor \| [^|]+ \| 1 \| 1h 01m \|$' "$RUNDIR/run-report.md"
}

@test "ns report: Checks breakdown counts the runs of each check and their total time (ns-x6)" {
  rm -f "$LOGS"/*.checks.log
  cp "$X6/feature.checks.log" "$X6/p1-core.checks.log" "$LOGS/"
  run ns report sbx-12
  assert_success
  grep -qF 'Checks breakdown' "$RUNDIR/run-report.md"
  # python test: 5s + 10s + 15s on feature, 30s on p1-core; python lint: 4s twice
  grep -qF '| python test | 4 | 1m |' "$RUNDIR/run-report.md"
  grep -qF '| python lint | 2 | 8s |' "$RUNDIR/run-report.md"
}

@test "ns report: a cut-off Agent call takes its time to the last assistant message (ns-x6)" {
  rm -f "$LOGS"/*
  cp "$X6/conductor-agent-cut.jsonl" "$LOGS/conductor.jsonl"
  run ns report sbx-12
  assert_success
  # 10:05:00 to 10:35:00 is 30m
  grep -qE '^\| ns:integrator \| conductor \| unknown \| 1 \| 30m \|$' "$RUNDIR/run-report.md"
}

@test "ns report: a model with only partial tokens shows no data for its cost (ns-x6)" {
  rm -f "$LOGS"/*
  cp "$X6/conductor-cut-off.jsonl" "$LOGS/conductor.jsonl"
  run ns report sbx-12
  assert_success
  grep -qE '^\| claude-opus-5-5 \|.*\| no data \|$' "$RUNDIR/run-report.md"
}

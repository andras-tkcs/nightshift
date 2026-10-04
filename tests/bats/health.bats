#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  FIX="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIX/.claude"
  cat >"$FIX/.claude/project-profile.yaml" <<'EOP'
project: nightshift-sandbox
prefix: sbx
commands:
  setup: "true"
git: {}
stacks: [python]
EOP
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  SBX="$NS_CODING_DIR/worktrees/nightshift-sandbox"
  # A live pid for the stub tmux pane (the stub default 999999 is dead).
  export TMUX_STUB_PANE_PID=$$
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

ledger_of() { printf '%s/.nightshift/runs/%s/ledger.yaml\n' "$SBX-$1" "$1"; }

# running_run <id>: a running run with a live tmux session and a conductor log.
running_run() {
  ns new "$1" --tier T1 --yes >/dev/null
  ns-ledger set "$(ledger_of "$1")" '.state="running"'
  mkdir -p "$NS_CONFIG_DIR/logs/$1"
  : >"$NS_CONFIG_DIR/logs/$1/conductor.jsonl"
}

# NS_NOW is 2026-10-02T21:00:00Z; 34 min earlier:
age_log() { touch -d "2026-10-02T20:26:00Z" "$NS_CONFIG_DIR/logs/$1/conductor.jsonl"; }

@test "running run without a tmux session is dead in ns ls and ns status" {
  running_run sbx-12
  rm -f "$TMUX_STUB_DIR/sbx-12"
  run ns ls
  assert_success
  [[ "${lines[1]}" == *" dead "* ]]
  run ns status sbx-12
  assert_success
  assert_output_contains "health   dead"
}

@test "running run with a live session and a fresh log is ok" {
  running_run sbx-12
  touch -d "2026-10-02T20:59:00Z" "$NS_CONFIG_DIR/logs/sbx-12/conductor.jsonl"
  run ns status sbx-12
  assert_success
  assert_output_contains "health   ok"
}

@test "running run with a 34 minute old log is silent 34m" {
  running_run sbx-12
  age_log sbx-12
  run ns status sbx-12
  assert_success
  assert_output_contains "health   silent 34m"
  run ns ls
  assert_success
  assert_output_contains "silent 34m"
}

@test "an open gate is never silent" {
  running_run sbx-12
  ns-ledger set "$(ledger_of sbx-12)" '.gate="1"'
  age_log sbx-12
  run ns status sbx-12
  assert_success
  assert_output_contains "health   ok"
}

@test "NS_SILENT_SECS moves the silent threshold" {
  running_run sbx-12
  age_log sbx-12
  NS_SILENT_SECS=7200 run ns status sbx-12
  assert_success
  assert_output_contains "health   ok"
}

@test "ns ls has ELAPSED and LAST-OUT columns" {
  NS_NOW=2026-10-02T20:00:00Z ns new sbx-12 --tier T1 --yes >/dev/null
  ns-ledger set "$(ledger_of sbx-12)" '.state="running"'
  mkdir -p "$NS_CONFIG_DIR/logs/sbx-12"
  : >"$NS_CONFIG_DIR/logs/sbx-12/conductor.jsonl"
  touch -d "2026-10-02T20:26:00Z" "$NS_CONFIG_DIR/logs/sbx-12/conductor.jsonl"
  run ns ls
  assert_success
  assert_output_contains "ELAPSED"
  assert_output_contains "LAST-OUT"
  [[ "${lines[1]}" == *"1h"* ]]
  [[ "${lines[1]}" == *"34m"* ]]
}

@test "ns ls LAST-OUT is - without a log" {
  ns new sbx-12 --tier T1 --yes >/dev/null
  run ns ls
  assert_success
  assert_output_contains "LAST-OUT"
  [[ "${lines[1]}" == *" -" ]]
}

@test "ns ls --json adds health, elapsed_s and idle_s" {
  NS_NOW=2026-10-02T20:00:00Z ns new sbx-12 --tier T1 --yes >/dev/null
  ns-ledger set "$(ledger_of sbx-12)" '.state="running"'
  mkdir -p "$NS_CONFIG_DIR/logs/sbx-12"
  : >"$NS_CONFIG_DIR/logs/sbx-12/conductor.jsonl"
  touch -d "2026-10-02T20:26:00Z" "$NS_CONFIG_DIR/logs/sbx-12/conductor.jsonl"
  run ns ls --json
  assert_success
  [ "$(jq -r '.[0].health' <<<"$output")" = "silent 34m" ]
  [ "$(jq -r '.[0].elapsed_s' <<<"$output")" = 3600 ]
  [ "$(jq -r '.[0].idle_s' <<<"$output")" = 2040 ]
}

@test "health-check notifies once for a dead run and clears on recovery" {
  export NS_NTFY_TOPIC=t
  running_run sbx-12
  rm -f "$TMUX_STUB_DIR/sbx-12"
  run ns health-check
  assert_success
  [ "$(grep -c '^curl ' "$NS_STUB_LOG")" = 1 ]
  [ -e "$NS_CONFIG_DIR/health/sbx-12" ]
  run ns health-check
  assert_success
  [ "$(grep -c '^curl ' "$NS_STUB_LOG")" = 1 ]
  # recovery: the session is back and the log is fresh
  printf 'DIR x\n' >"$TMUX_STUB_DIR/sbx-12"
  touch -d "2026-10-02T20:59:00Z" "$NS_CONFIG_DIR/logs/sbx-12/conductor.jsonl"
  run ns health-check
  assert_success
  [ ! -e "$NS_CONFIG_DIR/health/sbx-12" ]
}

@test "health-check notifies for a silent run and stays quiet for a healthy one" {
  export NS_NTFY_TOPIC=t
  running_run sbx-12
  touch -d "2026-10-02T20:59:00Z" "$NS_CONFIG_DIR/logs/sbx-12/conductor.jsonl"
  run ns health-check
  assert_success
  [ "$(grep -c '^curl ' "$NS_STUB_LOG")" = 0 ]
  age_log sbx-12
  run ns health-check
  assert_success
  [ "$(grep -c '^curl ' "$NS_STUB_LOG")" = 1 ]
}

@test "health-check notifies again when a silent run becomes dead, not when silence grows" {
  export NS_NTFY_TOPIC=t
  running_run sbx-12
  age_log sbx-12
  run ns health-check
  [ "$(grep -c '^curl ' "$NS_STUB_LOG")" = 1 ]
  touch -d "2026-10-02T20:00:00Z" "$NS_CONFIG_DIR/logs/sbx-12/conductor.jsonl"
  run ns health-check
  [ "$(grep -c '^curl ' "$NS_STUB_LOG")" = 1 ]
  rm -f "$TMUX_STUB_DIR/sbx-12"
  run ns health-check
  assert_success
  [ "$(grep -c '^curl ' "$NS_STUB_LOG")" = 2 ]
}

@test "health-check removes the incident file of a run that is gone" {
  export NS_NTFY_TOPIC=t
  mkdir -p "$NS_CONFIG_DIR/health"
  printf 'dead\n' >"$NS_CONFIG_DIR/health/sbx-99"
  run ns health-check
  assert_success
  [ ! -e "$NS_CONFIG_DIR/health/sbx-99" ]
}

@test "stream-view survives malformed events and keeps going" {
  big=$(head -c 300000 /dev/zero | tr '\0' x)
  {
    printf '%s\n' '[1,2]' '"str"' 'null' '42' 'not json' '{"type":"assistant"}' \
      '{"type":"assistant","message":null}' \
      '{"type":"assistant","message":{"content":[null,1,"x",{"type":"text","text":null},{"type":"tool_use","name":null,"input":{"a":{1,2}}}]}}' \
      '{"type":"assistant","message":{"content":42}}' \
      '{"type":"assistant","message":"oops"}' \
      '{"type":"result","total_cost_usd":"abc","num_turns":null}' \
      '{"type":"result","total_cost_usd":[1]}'
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$big"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"still alive"}]}}'
  } >"$BATS_TEST_TMPDIR/bad.jsonl"
  run "$NS_REPO_ROOT/bin/lib/stream-view.py" <"$BATS_TEST_TMPDIR/bad.jsonl"
  assert_success
  assert_output_contains "still alive"
}

@test "stream-view exits 0 when stdout is closed" {
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"a"}]}}' >"$BATS_TEST_TMPDIR/one.jsonl"
  run bash -c "'$NS_REPO_ROOT/bin/lib/stream-view.py' <'$BATS_TEST_TMPDIR/one.jsonl' >&-"
  assert_success
}

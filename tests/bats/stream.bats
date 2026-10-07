#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  FX="$NS_REPO_ROOT/tests/fixtures/stream"
  LOGS="$NS_CONFIG_DIR/logs"
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

view() { COLUMNS=80 "$NS_REPO_ROOT/bin/lib/stream-view.py" <"$FX/$1.jsonl"; }

@test "stream-view output equals the expected text at 80 columns" {
  local c
  for c in bash-long edit-long result-error result-ok; do
    run view "$c"
    assert_success
    [ "$output" = "$(cat "$FX/$c.txt")" ] || { echo "case $c differs" >&2; return 1; }
  done
}

@test "stream-view never truncates with an ellipsis" {
  local c
  for c in bash-long edit-long; do
    run view "$c"
    assert_output_not_contains "..."
    assert_output_not_contains "…"
  done
  run view bash-long
  assert_output_contains "tests/bats/run-new.bats"
}

@test "stream-view wraps at COLUMNS with a hanging indent" {
  run view bash-long
  [ "${#lines[@]}" -ge 2 ]
  local l
  for l in "${lines[@]}"; do [ "${#l}" -le 80 ]; done
  [[ ${lines[1]} == "      "[!\ ]* ]]
}

@test "stream-view honours a narrower COLUMNS" {
  run bash -c "COLUMNS=40 '$NS_REPO_ROOT/bin/lib/stream-view.py' < '$FX/bash-long.jsonl'"
  assert_success
  local l
  for l in "${lines[@]}"; do [ "${#l}" -le 40 ]; done
}

@test "stream-view result lines: error carries exit code, ok is short" {
  run view result-error
  [[ $output == *"result: error, exit 2: "* ]]
  run view result-ok
  [ "$output" = "21:00 result: ok" ]
}

mklogs() {
  mkdir -p "$LOGS/sbx-1"
  cp "$FX/result-ok.jsonl" "$LOGS/sbx-1/intake.jsonl"
  cp "$FX/result-error.jsonl" "$LOGS/sbx-1/p1.jsonl"
}

@test "ns log renders the whole run from all phase logs" {
  mklogs
  run ns log sbx-1
  assert_success
  assert_output_contains "result: ok"
  assert_output_contains "result: error, exit 2"
}

@test "ns log --phase shows only that phase" {
  mklogs
  run ns log sbx-1 --phase p1
  assert_success
  assert_output_contains "result: error, exit 2"
  assert_output_not_contains "result: ok"
}

@test "ns log --raw prints the JSONL unchanged" {
  mklogs
  run ns log sbx-1 --phase p1 --raw
  assert_success
  [ "$output" = "$(cat "$FX/result-error.jsonl")" ]
}

@test "ns log -f follows through tail -f" {
  mklogs
  run timeout 2 ns log sbx-1 --phase intake -f
  assert_output_contains "result: ok"
}

@test "ns log with a missing id or log exits 1 with a message" {
  run ns log
  assert_failure 1
  run ns log nope-9
  assert_failure 1
  assert_output_contains "nope-9"
  mkdir -p "$LOGS/sbx-2"
  run ns log sbx-2
  assert_failure 1
  mklogs
  run ns log sbx-1 --phase nophase
  assert_failure 1
  assert_output_contains "nophase"
}

@test "stream-view keeps going after invalid UTF-8 and a string message" {
  printf '\xff\xfe{"type":"x"}\n{"type":"assistant","message":"oops"}\n{"type":"assistant","message":{"content":"after"}}\n' \
    >"$BATS_TEST_TMPDIR/bad.jsonl"
  run "$NS_REPO_ROOT/bin/lib/stream-view.py" <"$BATS_TEST_TMPDIR/bad.jsonl"
  assert_success
  assert_output_contains "text: after"
}

@test "stream-view stamps each line with the event's own timestamp, not the current time (ns-x6)" {
  run view timestamps
  assert_success
  [[ ${lines[0]} == "08:01 text: first" ]]
  [[ ${lines[1]} == "09:15 result: ok" ]]
  [[ ${lines[2]} == "10:42 tool: Bash ls" ]]
}

@test "ns log shows each event's real time (ns-x6)" {
  mkdir -p "$LOGS/sbx-1"
  cp "$FX/timestamps.jsonl" "$LOGS/sbx-1/intake.jsonl"
  run ns log sbx-1
  assert_success
  assert_output_contains "08:01 text: first"
  assert_output_contains "10:42 tool: Bash ls"
  assert_output_not_contains "21:00"
}

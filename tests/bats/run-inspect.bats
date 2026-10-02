#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  FIX="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIX/.claude"
  cat >"$FIX/.claude/project-profile.yaml" <<'EOF'
project: nightshift-sandbox
prefix: sbx
commands:
  setup: "true"
git: {}
stacks: [python]
EOF
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  SBX="$NS_CODING_DIR/worktrees/nightshift-sandbox"
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

ledger_of() { printf '%s/.nightshift/runs/%s/ledger.yaml\n' "$SBX-$1" "$1"; }

@test "ns ls with no runs prints no runs" {
  run ns ls
  assert_success
  [ "$output" = "no runs" ]
}

@test "ns ls prints header and one row per run in creation order" {
  NS_NOW=2026-10-02T20:00:00Z ns new sbx-12 --tier T1 --yes >/dev/null
  NS_NOW=2026-10-02T20:30:00Z ns new sbx "text run" --tier T2 --yes >/dev/null
  run ns ls
  assert_success
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "$(printf '%-14s %-4s %-18s %-8s %-14s %s' ID TIER PHASE STATE WAITING-ON AGE)" ]
  [ "${lines[1]}" = "$(printf '%-14s %-4s %-18s %-8s %-14s %s' sbx-12 T1 intake queued - 1h)" ]
  [ "${lines[2]}" = "$(printf '%-14s %-4s %-18s %-8s %-14s %s' sbx-x1 T2 intake queued - 30m)" ]
}

@test "ns ls shows running phases, gate and pool" {
  ns new sbx-12 --tier T1 --yes >/dev/null
  ns new sbx-13 --tier T1 --yes >/dev/null
  ns new sbx-14 --tier T1 --yes >/dev/null
  ns-ledger set "$(ledger_of sbx-12)" '.state="waiting" | .gate="1"'
  ns-ledger set "$(ledger_of sbx-13)" '.phases=[{id:"p1-a",title:"a",state:"queued",branch:null,worktree:null,attempts:0,review_rounds:0}]'
  ns-ledger set "$(ledger_of sbx-14)" '.state="running" | .phases=[{id:"p1-a",title:"a",state:"running",branch:null,worktree:null,attempts:1,review_rounds:0},{id:"p2-b",title:"b",state:"review",branch:null,worktree:null,attempts:1,review_rounds:0}]'
  run ns ls
  assert_success
  assert_output_contains "owner:gate1"
  assert_output_contains "pool"
  assert_output_contains "p1-a,p2-b"
}

@test "ns ls shows ? and no-worktree for a deleted worktree" {
  ns new sbx-12 --tier T1 --yes >/dev/null
  rm -rf "$SBX-sbx-12"
  run ns ls
  assert_success
  assert_output_contains "no-worktree"
  [[ "${lines[1]}" == *" ?  "* ]]
}

@test "ns ls --json parses and has id" {
  ns new sbx-12 --tier T1 --yes >/dev/null
  run ns ls --json
  assert_success
  [ "$(jq -r '.[0].id' <<<"$output")" = sbx-12 ]
  [ "$(jq -r '.[0].tier' <<<"$output")" = T1 ]
  [ "$(jq -r '.[0].phases | length' <<<"$output")" = 0 ]
}

@test "ns ls --all includes an archived run" {
  ns new sbx-12 --tier T1 --yes >/dev/null
  ns new sbx-13 --tier T1 --yes >/dev/null
  bash -c 'source "$NS_HOME/bin/lib/common.sh"; source "$NS_HOME/bin/lib/config.sh"; source "$NS_HOME/bin/lib/runs.sh"; ns_run_set sbx-13 ".archived=true"'
  run ns ls
  assert_success
  assert_output_not_contains "sbx-13"
  run ns ls --all
  assert_success
  assert_output_contains "sbx-13"
  run ns ls --json
  [ "$(jq length <<<"$output")" = 1 ]
}

@test "ns status prints the run summary" {
  ns new sbx-12 --tier T1 --yes >/dev/null
  ns-ledger set "$(ledger_of sbx-12)" '.phases=[{id:"p1-x",title:"x",state:"merged",branch:"feature/12--p1-x",worktree:null,attempts:1,review_rounds:1}]'
  run ns status sbx-12
  assert_success
  assert_output_contains "run      sbx-12 (nightshift-sandbox)"
  assert_output_contains "tier     T1 (owner"
  assert_output_contains "state    queued · gate - · step intake"
  assert_output_contains "budget   0 h of 2 h"
  assert_output_contains "branches plan/sbx-12 · - · pr -"
  assert_output_contains "  p1-x      merged    feature/12--p1-x  attempts 1  rounds 1"
  assert_output_contains "events (last 5)"
  assert_output_contains "  created  "
  run ns status sbx-99
  assert_failure 1
  assert_output_contains "unknown run sbx-99"
}

@test "ns status --json equals ns-ledger get" {
  ns new sbx-12 --tier T1 --yes >/dev/null
  run ns status sbx-12 --json
  assert_success
  [ "$(jq -S . <<<"$output")" = "$(ns-ledger get "$(ledger_of sbx-12)" | jq -S .)" ]
}

@test "ns attach attaches when a session exists" {
  ns new sbx-12 --tier T1 --yes >/dev/null
  run ns attach sbx-12
  assert_success
  [ "$output" = "attached sbx-12" ]
}

@test "ns attach without a session exits 1" {
  ns new sbx-12 --tier T1 --yes >/dev/null
  rm -f "$TMUX_STUB_DIR/sbx-12"
  run ns attach sbx-12
  assert_failure 1
  assert_output_contains "no tmux session sbx-12: start it with ns resume sbx-12"
}

@test "ns stop requests a stop and is idempotent on a stopped run" {
  ns new sbx-12 --tier T1 --yes >/dev/null
  run ns stop sbx-12
  assert_success
  assert_output_contains "stop requested for sbx-12; it stops at its next checkpoint"
  [ "$(ns-ledger get "$(ledger_of sbx-12)" .stop_requested)" = stopped ]
  [ "$(ns-ledger get "$(ledger_of sbx-12)" '[.events[].type] | index("stop-requested") != null')" = true ]
  ns-ledger set "$(ledger_of sbx-12)" '.state="stopped"'
  run ns stop sbx-12
  assert_success
  [ "$output" = "sbx-12 is already stopped" ]
}

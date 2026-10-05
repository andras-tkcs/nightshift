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
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }
ledger() { printf '%s' "$SBX-$1/.nightshift/runs/$1/ledger.yaml"; }
lget() { ns-ledger get "$(ledger "$1")" "$2"; }
set_max_runs() { printf 'max_runs: %s\n' "$1" >"$NS_CONFIG_DIR/config.yaml"; }

# live_run <n>: a run with a live conductor (stub session) in state running
live_run() {
  ns new "sbx-$1" --tier T1 --yes >/dev/null
  ns-ledger set "$(ledger "sbx-$1")" '.state="running"'
  : >"$TMUX_STUB_DIR/sbx-$1"
}

# end_session <n>: the conductor of a live run ended (it parked)
end_session() {
  rm -f "$TMUX_STUB_DIR/sbx-$1"
  ns-ledger set "$(ledger "sbx-$1")" '.state="parked"'
}

sessions() { find "$TMUX_STUB_DIR" -type f | wc -l | tr -d ' '; }

@test "ns new queues a run at the limit; a finished conductor starts it" {
  set_max_runs 1
  live_run 11
  run ns new sbx-12 --tier T1 --yes
  assert_success
  assert_output_contains "queued sbx-12: 1 of 1 runs active (starts when one finishes)"
  [ "$(lget sbx-12 .state)" = queued ]
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
  [ -d "$SBX-sbx-12" ]
  end_session 11
  run ns dequeue
  assert_success
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
  [ "$(lget sbx-12 .state)" = running ]
  [ "$(lget sbx-12 '[.events[].type] | index("dequeued") != null')" = true ]
}

@test "ns dequeue leaves the queue alone while no slot is free" {
  set_max_runs 1
  live_run 11
  ns new sbx-12 --tier T1 --yes >/dev/null
  run ns dequeue
  assert_success
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
  [ "$(lget sbx-12 .state)" = queued ]
}

@test "ns new --now starts a run past the limit" {
  set_max_runs 1
  live_run 11
  run ns new sbx-12 --tier T1 --yes --now
  assert_success
  assert_output_contains "started sbx-12"
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
}

@test "two concurrent dequeues with one free slot start exactly one run" {
  set_max_runs 1
  live_run 11
  ns new sbx-12 --tier T1 --yes >/dev/null
  ns new sbx-13 --tier T1 --yes >/dev/null
  end_session 11
  ns dequeue >"$BATS_TEST_TMPDIR/d1.out" 2>&1 &
  p1=$!
  ns dequeue >"$BATS_TEST_TMPDIR/d2.out" 2>&1 &
  p2=$!
  wait "$p1"
  wait "$p2"
  [ "$(sessions)" = 1 ]
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
  [ ! -e "$TMUX_STUB_DIR/sbx-13" ]
  [ "$(lget sbx-13 .state)" = queued ]
}

@test "ns resume --all respects max_runs: two start, one stays queued" {
  set_max_runs 5
  for n in 21 22 23; do
    ns new "sbx-$n" --tier T1 --yes >/dev/null
    end_session "$n"
  done
  set_max_runs 2
  run ns resume --all
  assert_success
  [ "$(sessions)" = 2 ]
  queued=0
  for n in 21 22 23; do
    if [ "$(lget "sbx-$n" .state)" = queued ]; then queued=$((queued + 1)); fi
  done
  [ "$queued" = 1 ]
  assert_output_contains "queued sbx-"
}

@test "ns ls shows WAITING-ON runs and ns status the queue position" {
  set_max_runs 1
  live_run 11
  ns new sbx-12 --tier T1 --yes >/dev/null
  run ns ls
  assert_success
  line=$(grep '^sbx-12 ' <<<"$output")
  [[ $line == *" runs "* ]]
  run ns status sbx-12
  assert_success
  assert_output_contains "position 1 of 1"
}

@test "the queue lock is free after ns new, even when tmux leaves a daemon behind" {
  export TMUX_STUB_LEAK="$BATS_TEST_TMPDIR/leak.pid"
  run ns new sbx-31 --tier T1 --yes
  assert_success
  [ -s "$TMUX_STUB_LEAK" ]
  kill -0 "$(cat "$TMUX_STUB_LEAK")"
  run flock -n "$NS_CONFIG_DIR/queue.lock" true
  kill "$(cat "$TMUX_STUB_LEAK")" 2>/dev/null || true
  assert_success
}

@test "a queued run created without --tier (triage left it running) is queued and dequeued" {
  set_max_runs 1
  live_run 11
  cat >"$BATS_TEST_TMPDIR/triage.sh" <<'EOS'
ns-ledger set "$NS_LEDGER" '.tier_recommended="T1"'
ns-ledger state "$NS_LEDGER" running
EOS
  export CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/triage.sh"
  run ns new sbx-12 --yes
  assert_success
  assert_output_contains "queued sbx-12"
  [ "$(lget sbx-12 .state)" = queued ]
  [ "$(lget sbx-12 .queued_for_slot)" = true ]
  end_session 11
  run ns dequeue
  assert_success
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
  [ "$(lget sbx-12 .state)" = running ]
  [ "$(lget sbx-12 .queued_for_slot)" = false ]
}

@test "ns dequeue during ns new does not start the half-created run" {
  set_max_runs 5
  cat >"$BATS_TEST_TMPDIR/triage.sh" <<'EOS'
ns-ledger set "$NS_LEDGER" '.tier_recommended="T1"'
ns dequeue >"$(dirname "$NS_LEDGER")/../../../dequeue.out" 2>&1
EOS
  export CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/triage.sh"
  run ns new sbx-12 --yes
  assert_success
  assert_output_contains "started sbx-12"
  [ "$(lget sbx-12 '[.events[].type] | index("dequeued") == null')" = true ]
  grep -q "0 started" "$SBX-sbx-12/dequeue.out"
}

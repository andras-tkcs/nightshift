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
  test: "true"
git: {}
stacks: [python]
EOF
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T2 --yes >/dev/null
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  LEDGER="$WT/.nightshift/runs/sbx-12/ledger.yaml"
  mkdir -p "$WT/docs"
  cp "$NS_REPO_ROOT/tests/fixtures/plans/two-phase-plan.md" "$WT/docs/sbx-12-plan.md"
  git -C "$WT" add docs/sbx-12-plan.md
  git -C "$WT" commit -q -m "plan"
  git -C "$WT" branch feature/12 origin/main
  git -C "$WT" push -q origin feature/12
  ns-ledger set "$LEDGER" '.feature_branch = "feature/12"'
  export NS_WORKER_MODE=bypassPermissions
  cat >"$BATS_TEST_TMPDIR/worker.sh" <<'EOF'
phase=${NS_PHASE:?}
echo "$phase" >"$phase.txt"
git add "$phase.txt"
git commit -q -m "add $phase"
git push -q -u origin HEAD
EOF
  cat >"$BATS_TEST_TMPDIR/sleeper.sh" <<'EOF'
sleep 60
EOF
  export CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/worker.sh"
  export CLAUDE_STUB_RESULT="PHASE-REPORT p1-alpha status=done head=abc"
}

teardown() {
  local f pid
  for f in "$NS_CONFIG_DIR"/workers/*.pid; do
    [ -f "$f" ] || continue
    pid=$(sed -n 's/^pid=//p' "$f")
    [ -z "$pid" ] || kill -KILL -- "-$pid" 2>/dev/null || true
  done
  return 0
}

lget() { ns-ledger get "$LEDGER" "$1"; }
pstate() { lget "(.phases[] | select(.id == \"$1\") | .$2)"; }

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }
lget() { ns-ledger get "$LEDGER" "$1"; }

alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(ps -o stat= -p "$1" | tr -d ' ' | cut -c1)" != Z ]
}

@test "ns stop on a run with no conductor stops it at once" {
  ns-ledger set "$LEDGER" '.state="waiting" | .gate="1"'
  rm -f "$TMUX_STUB_DIR/sbx-12"
  run ns stop sbx-12
  assert_success
  [ "$(lget .state)" = stopped ]
  [ "$(lget '.stop_requested // "none"')" = none ]
  [[ "$output" != *"next checkpoint"* ]]
}

@test "ns kill ends the session and the worker group, keeps the worktree" {
  export NS_NTFY_TOPIC=topic1
  : >"$TMUX_STUB_DIR/sbx-12"
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/sleeper.sh" run ns-conductor start sbx-12 p1-alpha
  assert_success
  pid=$(sed -n 's/^pid=//p' "$NS_CONFIG_DIR/workers/sbx-12--p1-alpha.pid")
  alive "$pid"
  ns-ledger set "$LEDGER" '.state="running"'
  run ns kill sbx-12
  assert_success
  ! alive "$pid"
  [ -z "$(pgrep -g "$pid" || true)" ]
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
  [ "$(lget .state)" = stopped ]
  [ "$(lget '[.phases[] | select(.state == "running")] | length')" = 0 ]
  [ "$(lget '[.events[].message] | map(select(test("killed by owner"))) | length > 0')" = true ]
  [ "$(grep -c 'ntfy.sh/topic1' "$NS_STUB_LOG")" = 1 ]
  [ -d "$WT" ]
  git -C "$WT" rev-parse --verify -q feature/12
  run ns resume sbx-12
  assert_success
}

@test "ns kill on an already stopped run is a no-op" {
  ns-ledger set "$LEDGER" '.state="stopped"'
  run ns kill sbx-12
  assert_success
  [ "$(lget .state)" = stopped ]
}

#!/usr/bin/env bats

load helpers

fixture_vars() {
  FIX="$BATS_TEST_TMPDIR/fixture"
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  LEDGER="$WT/.nightshift/runs/sbx-12/ledger.yaml"
}

# the slow part of the setup, run once per file (ns_cached_fixture)
fixture_build() {
  fixture_vars
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
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T1 --yes >/dev/null
  rm -f "$TMUX_STUB_DIR/sbx-12"
}

setup() {
  ns_test_setup
  export NS_DRAIN_POLL=1
  ns_cached_fixture fixture_build
  fixture_vars
  PROJ="$(dirname "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)")"
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }
lget() { ns-ledger get "$LEDGER" "$1"; }

@test "drain asks a running run with a session to park" {
  ns-ledger set "$LEDGER" '.state="running"'
  : >"$TMUX_STUB_DIR/sbx-12"
  run ns drain --timeout 1
  assert_failure 1
  assert_output_contains "still running: sbx-12"
  [ "$(lget .stop_requested)" = parked ]
  [ "$(lget .state)" = running ]
}

@test "drain parks a run without a session directly" {
  ns-ledger set "$LEDGER" '.state="running"'
  run ns drain --timeout 5
  assert_success
  [ "$output" = "parked: sbx-12" ]
  [ "$(lget .state)" = parked ]
}

@test "drain leaves a waiting run alone" {
  ns-ledger set "$LEDGER" '.state="waiting"'
  run ns drain --timeout 5
  assert_success
  [ "$(lget .state)" = waiting ]
  [ "$(lget '.stop_requested // "none"')" = none ]
}

@test "drain returns once a background loop parks the run" {
  ns-ledger set "$LEDGER" '.state="running"'
  : >"$TMUX_STUB_DIR/sbx-12"
  (sleep 0.5 && ns-ledger set "$LEDGER" '.state="parked"') &
  run ns drain --timeout 30
  wait
  assert_success
  [ "$output" = "parked: sbx-12" ]
}

@test "drain exits 1 with still running on a timeout" {
  ns-ledger set "$LEDGER" '.state="running"'
  : >"$TMUX_STUB_DIR/sbx-12"
  run ns drain --timeout 1
  assert_failure 1
  assert_output_contains "still running: sbx-12"
}

@test "up starts the rc session in the first project with remote control" {
  run ns up
  assert_output_contains "Remote Control: started"
  [ -f "$TMUX_STUB_DIR/rc" ]
  grep -q "^DIR $PROJ\$" "$TMUX_STUB_DIR/rc"
  grep -q 'CMD exec claude remote-control --spawn worktree' "$TMUX_STUB_DIR/rc"
}

@test "up does not start a second rc session" {
  ns up >/dev/null || true
  run ns up
  assert_output_contains "Remote Control: already running"
  [ "$(grep -c 'new-session.* rc ' "$NS_STUB_LOG")" -eq 1 ]
}

@test "up prints the resume hint when a run is parked" {
  ns-ledger set "$LEDGER" '.state="parked"'
  run ns up
  assert_output_contains "parked: sbx-12"
  assert_output_contains "ns resume --all"
}

@test "up says so when no project is registered" {
  rm -f "$NS_CONFIG_DIR/projects.yaml" "$NS_CONFIG_DIR/runs.yaml"
  run ns up
  assert_output_contains "Remote Control: no project registered yet"
  [ ! -f "$TMUX_STUB_DIR/rc" ]
}

@test "the gc timer template is daily and persistent" {
  grep -qxF 'OnCalendar=*-*-* 04:00' "$NS_REPO_ROOT/templates/systemd/ns-gc.timer"
  grep -qxF 'Persistent=true' "$NS_REPO_ROOT/templates/systemd/ns-gc.timer"
  grep -qxF 'WantedBy=timers.target' "$NS_REPO_ROOT/templates/systemd/ns-gc.timer"
}

@test "drain keeps an owner's pending ns stop, so resume --all leaves the run stopped (#96)" {
  ns-ledger set "$LEDGER" '.state="running" | .stop_requested="stopped"'
  : >"$TMUX_STUB_DIR/sbx-12"
  run ns drain --timeout 1
  [ "$(lget .stop_requested)" = stopped ]
}

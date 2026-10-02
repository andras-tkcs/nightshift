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

run_field() { # <id> <jq filter on the ledger>
  ns-ledger get "$SBX-$1/.nightshift/runs/$1/ledger.yaml" "$2"
}

@test "text runs get x1, x2; issue runs the number" {
  run ns new sbx "fix the thing" --tier T1 --yes
  assert_success
  assert_output_contains "started sbx-x1 in tmux session sbx-x1: ns attach sbx-x1"
  run ns new sbx "another" --tier T1 --yes
  assert_success
  assert_output_contains "started sbx-x2"
  run ns new sbx-12 --tier T1 --yes
  assert_success
  assert_output_contains "started sbx-12"
  [ "$(run_field sbx-12 .request.issue)" = 12 ]
  [ "$(run_field sbx-x1 .request.text)" = "fix the thing" ]
}

@test "worktree, ledger, remote branch and tmux session" {
  run ns new sbx-12 --tier T1 --yes
  assert_success
  wt="$SBX-sbx-12"
  [ "$(git -C "$wt" branch --show-current)" = plan/sbx-12 ]
  [ "$(git -C "$wt" merge-base HEAD origin/main)" = "$(git -C "$wt" rev-parse origin/main)" ]
  [ "$(run_field sbx-12 .state)" = queued ]
  git -C "$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git" rev-parse --verify -q plan/sbx-12
  [ "$(grep '^CMD' "$TMUX_STUB_DIR/sbx-12")" = "CMD exec $NS_HOME/bin/ns-launch sbx-12" ]
  grep -q "^DIR $wt\$" "$TMUX_STUB_DIR/sbx-12"
  grep -q '^ENV NS_CONFIG_DIR=' "$TMUX_STUB_DIR/sbx-12"
  ! grep -q '^ENV NS_PLUGIN_DIRS=' "$TMUX_STUB_DIR/sbx-12"
  NS_PLUGIN_DIRS=/a:/b run ns new sbx-13 --tier T1 --yes
  assert_success
  grep -q '^ENV NS_PLUGIN_DIRS=/a:/b$' "$TMUX_STUB_DIR/sbx-13"
}

@test "--tier T1 --yes sets tier, source owner, limit 2" {
  run ns new sbx-5 --tier T1 --yes
  assert_success
  [ "$(run_field sbx-5 .tier)" = T1 ]
  [ "$(run_field sbx-5 .tier_source)" = owner ]
  [ "$(run_field sbx-5 .budget.limit)" = 2 ]
}

write_triage_script() {
  cat >"$BATS_TEST_TMPDIR/triage.sh" <<'EOF'
printf 'triage line 1\nline 2\n' >"$(dirname "$NS_LEDGER")/triage.md"
ns-ledger set "$NS_LEDGER" '.tier_recommended="T2"'
EOF
  export CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/triage.sh"
}

@test "--yes without --tier runs triage and takes the recommendation" {
  write_triage_script
  run ns new sbx-7 --yes
  assert_success
  assert_output_contains "triage line 1"
  [ "$(run_field sbx-7 .tier)" = T2 ]
  [ "$(run_field sbx-7 .tier_source)" = triage ]
  grep -q -- '--triage-only' "$BATS_TEST_TMPDIR/claude/call-1.args"
  [ -f "$TMUX_STUB_DIR/sbx-7" ]
}

@test "answering T3 gives T3 from the owner" {
  write_triage_script
  run bash -c "echo T3 | '$NS_REPO_ROOT/bin/ns' new sbx-8"
  assert_success
  [ "$(run_field sbx-8 .tier)" = T3 ]
  [ "$(run_field sbx-8 .tier_source)" = owner ]
}

@test "answering n stops the run" {
  write_triage_script
  run bash -c "echo n | '$NS_REPO_ROOT/bin/ns' new sbx-9"
  assert_success
  assert_output_contains "stopped; ns resume sbx-9"
  [ "$(run_field sbx-9 .state)" = stopped ]
  [ ! -f "$TMUX_STUB_DIR/sbx-9" ]
}

@test "rerun: running exits 0, no session exits 1, unknown prefix exits 1" {
  ns new sbx-12 --tier T1 --yes
  run ns new sbx-12 --tier T1 --yes
  assert_success
  assert_output_contains "sbx-12 is already running: ns attach sbx-12"
  rm "$TMUX_STUB_DIR/sbx-12"
  run ns new sbx-12 --tier T1 --yes
  assert_failure 1
  assert_output_contains "run sbx-12 exists: use ns resume sbx-12"
  run ns new zzz-1 --tier T1 --yes
  assert_failure 1
  assert_output_contains "unknown prefix zzz"
}

@test "a project without a profile refuses ns new (R-ONB-5)" {
  make_remote acme/bare
  ns project add acme/bare --prefix bare >/dev/null
  run ns new bare-3 --tier T1 --yes
  assert_failure 1
  assert_output_contains "acme/bare has no profile on main: ns project add starts onboarding, or run ns new bare-onboard --onboard"
  ledger=$(ns_run_ledger_of bare-onboard)
  ns-ledger set "$ledger" '.pr="https://example.invalid/pr/1"'
  run ns new bare-3 --tier T1 --yes
  assert_failure 1
  assert_output_contains "onboarding PR https://example.invalid/pr/1 is not merged yet"
}

ns_run_ledger_of() {
  python3 "$NS_REPO_ROOT/bin/lib/nsyaml.py" to-json "$NS_CONFIG_DIR/runs.yaml" |
    jq -r --arg i "$1" '.runs[] | select(.id == $i) | .worktree + "/.nightshift/runs/" + $i + "/ledger.yaml"'
}

@test "ns project add on a repo without a profile creates sbx-onboard" {
  make_remote acme/other
  run ns project add acme/other --prefix oth
  assert_success
  ledger=$(ns_run_ledger_of oth-onboard)
  [ "$(ns-ledger get "$ledger" .tier)" = T1 ]
  [ "$(ns-ledger get "$ledger" .tier_source)" = owner ]
  [ -f "$TMUX_STUB_DIR/oth-onboard" ]
}

@test "ns-launch passes the documented arguments" {
  NS_PLUGIN_DIRS=/p/one:/p/two ns new sbx-12 --tier T1 --yes
  run ns-launch sbx-12
  assert_success
  args="$BATS_TEST_TMPDIR/claude/call-1.args"
  grep -qx -- '-p' "$args"
  [ "$(grep -A1 -x -- '--permission-mode' "$args" | tail -1)" = auto ]
  [ "$(grep -A1 -x -- '--output-format' "$args" | tail -1)" = stream-json ]
  grep -qx -- '--verbose' "$args"
  [ "$(grep -c -x -- '--plugin-dir' "$args")" = 0 ]
  [ "$(tail -1 "$args")" = "/ns:run sbx-12" ]
  NS_PLUGIN_DIRS=/p/one:/p/two run ns-launch sbx-12 --resume
  [ "$(grep -c -x -- '--plugin-dir' "$BATS_TEST_TMPDIR/claude/call-2.args")" = 2 ]
  grep -qx '/p/two' "$BATS_TEST_TMPDIR/claude/call-2.args"
  [ "$(tail -1 "$BATS_TEST_TMPDIR/claude/call-2.args")" = "/ns:run sbx-12 --resume" ]
  run ns-launch sbx-12 --triage
  [ "$(tail -1 "$BATS_TEST_TMPDIR/claude/call-3.args")" = "/ns:run sbx-12 --triage-only" ]
}

@test "ns-launch --onboard variant" {
  make_remote acme/other
  ns project add acme/other --prefix oth >/dev/null
  run ns-launch oth-onboard
  assert_success
  [ "$(tail -1 "$BATS_TEST_TMPDIR/claude/call-1.args")" = "/ns:run oth-onboard --onboard" ]
}

@test "the token reaches claude as an env var only" {
  mkdir -p "$NS_CONFIG_DIR/tokens"
  printf 'github_pat_%s\n' "AAAAAAAAAAAAAAAAAAAAAAAAAAAA" >"$NS_CONFIG_DIR/tokens/andras-tkcs"
  chmod 600 "$NS_CONFIG_DIR/tokens/andras-tkcs"
  ns new sbx-12 --tier T1 --yes
  run ns-launch sbx-12
  assert_success
  grep -qx 'token=set' "$BATS_TEST_TMPDIR/claude/call-1.env"
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/out.txt"
  refute_token_in "$BATS_TEST_TMPDIR/claude/call-1.args" "$NS_CONFIG_DIR/logs/sbx-12/conductor.jsonl" "$BATS_TEST_TMPDIR/out.txt" "$NS_STUB_LOG"
}

@test "stream-view renders the sample" {
  run bash -c "'$NS_REPO_ROOT/bin/lib/stream-view.py' < '$NS_REPO_ROOT/tests/fixtures/stream/sample.jsonl'"
  assert_success
  [ "$output" = "$(cat "$NS_REPO_ROOT/tests/fixtures/stream/sample.out")" ]
}

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

teardown() {
  [ -z "${FAKE_BS_PID:-}" ] || kill "$FAKE_BS_PID" 2>/dev/null || true
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

run_field() { # <id> <jq filter on the ledger>
  ns-ledger get "$SBX-$1/.nightshift/runs/$1/ledger.yaml" "$2"
}

@test "text runs get x1, x2; issue runs the number" {
  printf 'max_runs: 5\n' >"$NS_CONFIG_DIR/config.yaml"
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

@test "text runs skip x numbers whose plan branch is already on origin (e2e t2)" {
  remote="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
  git -C "$remote" branch plan/sbx-x1 main
  git -C "$remote" branch plan/sbx-x2 main
  run ns new sbx "fresh config, old branches" --tier T1 --yes
  assert_success
  assert_output_contains "started sbx-x3 in tmux session sbx-x3"
  [ "$(run_field sbx-x3 .request.text)" = "fresh config, old branches" ]
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

@test "ns new --from-desk seeds the request from a desk note, nothing in the repo, no PR (ns-76)" {
  mkdir -p "$NS_DESK_DIR/nightshift-sandbox/notes"
  printf '# Idea\n\nDo "this" and $that.\n' >"$NS_DESK_DIR/nightshift-sandbox/notes/idea.md"
  run ns new sbx --from-desk nightshift-sandbox/notes/idea.md --tier T1 --yes
  assert_success
  assert_output_contains "started sbx-x1"
  [ "$(run_field sbx-x1 .request.text)" = "$(printf '# Idea\n\nDo "this" and $that.')" ]
  [ ! -e "$SBX-sbx-x1/idea.md" ]
  [ -z "$(find "$SBX-sbx-x1" -name idea.md -not -path '*/.git/*')" ]
  ! grep -q 'pr create' "$GH_STUB_LOG"
}

@test "ns new --from-desk accepts an absolute path" {
  mkdir -p "$NS_DESK_DIR/nightshift-sandbox"
  printf 'absolute note\n' >"$NS_DESK_DIR/nightshift-sandbox/abs.md"
  run ns new sbx --from-desk "$NS_DESK_DIR/nightshift-sandbox/abs.md" --tier T1 --yes
  assert_success
  [ "$(run_field sbx-x1 .request.text)" = "absolute note" ]
}

@test "ns new --from-desk fails on a missing or empty file and on combined input" {
  run ns new sbx --from-desk nightshift-sandbox/nope.md --tier T1 --yes
  assert_failure
  assert_output_contains "nope.md"
  : >"$BATS_TEST_TMPDIR/empty.md"
  run ns new sbx --from-desk "$BATS_TEST_TMPDIR/empty.md" --tier T1 --yes
  assert_failure
  printf 'x\n' >"$BATS_TEST_TMPDIR/n.md"
  run ns new sbx "inline text" --from-desk "$BATS_TEST_TMPDIR/n.md" --tier T1 --yes
  assert_failure
  run ns new sbx-12 --from-desk "$BATS_TEST_TMPDIR/n.md" --tier T1 --yes
  assert_failure
  [ ! -d "$SBX-sbx-x1" ]
}

@test "ns new --from-desk refuses a path outside the desk unless --allow-outside (ns-95)" {
  printf 'outside note\n' >"$BATS_TEST_TMPDIR/n.md"
  mkdir -p "$NS_DESK_DIR/nightshift-sandbox"
  printf 'x\n' >"$NS_DESK_DIR/../x.md"
  run ns new sbx --from-desk ../x.md --tier T1 --yes
  assert_failure
  assert_output_contains "outside the desk"
  run ns new sbx --from-desk /etc/passwd --tier T1 --yes
  assert_failure
  assert_output_contains "outside the desk"
  run ns new sbx --from-desk "$BATS_TEST_TMPDIR/n.md" --tier T1 --yes
  assert_failure
  assert_output_contains "--allow-outside"
  [ ! -d "$SBX-sbx-x1" ]
  run ns new sbx --from-desk "$BATS_TEST_TMPDIR/n.md" --allow-outside --tier T1 --yes
  assert_success
  [ "$(run_field sbx-x1 .request.text)" = "outside note" ]
}

@test "ns new --from-desk refuses a note that holds a token (ns-95)" {
  mkdir -p "$NS_DESK_DIR/nightshift-sandbox/notes"
  printf 'key ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123456789" >"$NS_DESK_DIR/nightshift-sandbox/notes/t.md"
  run ns new sbx --from-desk nightshift-sandbox/notes/t.md --tier T1 --yes
  assert_failure
  assert_output_contains "token"
  [ ! -d "$SBX-sbx-x1" ]
}

# launched_running: sbx-12 is running and its conductor log already holds an older session
launched_running() {
  ns new sbx-12 --tier T2 --yes >/dev/null
  L="$SBX-sbx-12/.nightshift/runs/sbx-12/ledger.yaml"
  ns-ledger set "$L" '.state = "running"'
  mkdir -p "$NS_CONFIG_DIR/logs/sbx-12"
  printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your session limit · resets 10pm (UTC)"}' >"$NS_CONFIG_DIR/logs/sbx-12/conductor.jsonl"
}

@test "ns-launch parks a run whose conductor hit a usage limit, paused until the reset" {
  launched_running
  CLAUDE_STUB_RESULT_LINE='{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You'"'"'ve hit your session limit · resets 11pm (UTC)"}' \
    run ns-launch sbx-12 --resume
  [ "$(ns-ledger get "$L" .state)" = parked ]
  [ "$(ns-ledger get "$L" .budget.paused)" = true ]
  [ "$(ns-ledger get "$L" .budget.paused_until)" = 2026-10-02T23:01:00Z ]
  [ "$(ns-ledger get "$L" '[.events[] | select(.type == "usage-pause")] | length')" = 1 ]
}

@test "ns-launch backs off 15 minutes when the conductor's limit has no reset time" {
  launched_running
  CLAUDE_STUB_RESULT_LINE='{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your session limit"}' \
    run ns-launch sbx-12
  [ "$(ns-ledger get "$L" .state)" = parked ]
  [ "$(ns-ledger get "$L" .budget.paused_until)" = 2026-10-02T21:15:00Z ]
}

@test "ns-launch escalates to gate 1.5 when the conductor hit a limit that does not reset" {
  launched_running
  CLAUDE_STUB_RESULT_LINE='{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'re out of usage credits. Run /usage-credits to keep using Opus."}' \
    run ns-launch sbx-12
  [ "$(ns-ledger get "$L" .state)" = waiting ]
  [ "$(ns-ledger get "$L" .gate)" = 1.5 ]
  grep -q "out of usage credits" "$SBX-sbx-12/.nightshift/runs/sbx-12/escalation.md"
  grep -q "^## Owner's answer" "$SBX-sbx-12/.nightshift/runs/sbx-12/escalation.md"
}

@test "ns-launch parks a run that wait paused when the conductor ends without parking" {
  launched_running
  ns-ledger set "$L" '.budget.paused = true | .budget.paused_until = "2026-10-02T22:00:00Z"'
  run ns-launch sbx-12
  [ "$(ns-ledger get "$L" .state)" = parked ]
  [ "$(ns-ledger get "$L" .budget.paused_until)" = 2026-10-02T22:00:00Z ]
}

@test "ns-launch leaves a run alone after a normal conductor end, whatever the old log says" {
  launched_running
  run ns-launch sbx-12
  assert_success
  [ "$(ns-ledger get "$L" .state)" = running ]
  [ "$(ns-ledger get "$L" '.budget.paused')" = false ]
}

@test "ns-launch --resume clears an expired usage pause and the budget counts again" {
  launched_running
  ns-ledger set "$L" '.budget.paused = true | .budget.paused_until = "2026-10-02T20:30:00Z" | .budget.since = "2026-10-02T18:00:00Z"'
  run ns-launch sbx-12 --resume
  [ "$(ns-ledger get "$L" .budget.paused)" = false ]
  [ "$(ns-ledger get "$L" '.budget.paused_until // "none"')" = none ]
  [ "$(ns-ledger get "$L" .budget.since)" = 2026-10-02T21:00:00Z ]
  [ "$(ns-ledger get "$L" '[.events[] | select(.type == "usage-resume")] | length')" = 1 ]
  [ "$(ns-ledger get "$L" .state)" = running ]
}

@test "ns-launch keeps a pause that has not expired yet" {
  launched_running
  ns-ledger set "$L" '.budget.paused = true | .budget.paused_until = "2026-10-02T22:00:00Z"'
  run ns-launch sbx-12 --resume
  [ "$(ns-ledger get "$L" .budget.paused)" = true ]
  [ "$(ns-ledger get "$L" .state)" = parked ]
}

@test "an expired pause and a normal conductor end leave the run running, not parked and woken again" {
  export NS_NTFY_TOPIC=t
  launched_running
  ns-ledger set "$L" '.budget.paused = true | .budget.paused_until = "2026-10-02T20:30:00Z"'
  # the conductor's session ends without any start (for example in discovery)
  run ns-launch sbx-12
  [ "$(ns-ledger get "$L" .state)" = running ]
  rm -f "$TMUX_STUB_DIR/sbx-12"
  run ns health-check
  assert_success
  assert_output_not_contains "resumed sbx-12"
  run ns health-check
  assert_success
  assert_output_not_contains "resumed sbx-12"
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
  [ "$(ns-ledger get "$L" .state)" = running ]
  [ "$(grep -c '^curl ' "$NS_STUB_LOG")" = 1 ]
}

@test "the fourth conductor usage limit without progress escalates to gate 1.5" {
  launched_running
  for i in 1 2 3; do
    ns-ledger event "$L" usage-pause "conductor hit a usage limit; paused until 2026-10-02T20:0${i}:00Z: You've hit your session limit"
  done
  CLAUDE_STUB_RESULT_LINE='{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your session limit · resets 11pm (UTC)"}' \
    run ns-launch sbx-12
  [ "$(ns-ledger get "$L" .state)" = waiting ]
  [ "$(ns-ledger get "$L" .gate)" = 1.5 ]
  grep -q "4 conductor usage limits" "$SBX-sbx-12/.nightshift/runs/sbx-12/escalation.md"
  # progress in between resets the count
  ns-ledger set "$L" '.state = "running" | .gate = null'
  ns-ledger event "$L" phase-start "p1-x attempt: pid 1"
  CLAUDE_STUB_RESULT_LINE='{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your session limit · resets 11pm (UTC)"}' \
    run ns-launch sbx-12
  [ "$(ns-ledger get "$L" .state)" = parked ]
}

@test "an upgrade that starts during triage queues the new run instead of starting it (#78)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$NS_OPT"
  write_triage_script
  # bootstrap.sh takes the lock while triage runs, after ns new's first check passed
  fake_bootstrap
  printf 'printf "pid=%%s\\n" %s >"%s"\n' "$FAKE_BS_PID" "$NS_OPT/.upgrade.lock" >>"$BATS_TEST_TMPDIR/triage.sh"
  run ns new sbx-7 --yes
  assert_success
  assert_output_contains "upgrade"
  [ ! -e "$TMUX_STUB_DIR/sbx-7" ]
  [ "$(run_field sbx-7 .state)" = queued ]
  [ "$(run_field sbx-7 .queued_for_slot)" = true ]
  # the upgrade ends: ns dequeue starts it
  rm "$NS_OPT/.upgrade.lock"
  run ns dequeue
  assert_success
  assert_output_contains "1 started"
  [ -f "$TMUX_STUB_DIR/sbx-7" ]
}

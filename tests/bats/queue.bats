#!/usr/bin/env bats

load helpers
bats_require_minimum_version 1.5.0

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
  [ "$(lget sbx-12 '[.events[] | select(.type=="dequeued")] | length')" = 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR"/d1.out "$BATS_TEST_TMPDIR"/d2.out | grep -c ' 1 started')" = 1 ]
}

@test "dequeue mode skips a run another process already started (stale list)" {
  set_max_runs 2
  ns new sbx-12 --tier T1 --yes >/dev/null
  ns-ledger set "$(ledger sbx-12)" '.state="running" | .queued_for_slot=false'
  : >"$TMUX_STUB_DIR/sbx-12"
  NS_DEQUEUE=1 run ns resume sbx-12
  [ "$status" -ne 0 ]
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
  [ "$(lget sbx-12 '[.events[] | select(.type=="dequeued" or .type=="resumed")] | length')" = 0 ]
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

@test "a failed tmux start during ns dequeue leaves the run queued and reports nothing" {
  set_max_runs 1
  live_run 11
  ns new sbx-12 --tier T1 --yes >/dev/null
  end_session 11
  real_tmux=$(command -v tmux)
  mkdir -p "$BATS_TEST_TMPDIR/failbin"
  cat >"$BATS_TEST_TMPDIR/failbin/tmux" <<EOS
#!/usr/bin/env bash
[ "\${1:-}" != new-session ] || exit 1
exec "$real_tmux" "\$@"
EOS
  chmod +x "$BATS_TEST_TMPDIR/failbin/tmux"
  export NS_STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  PATH="$BATS_TEST_TMPDIR/failbin:$PATH" run ns dequeue
  assert_output_contains "0 started, 1 still queued"
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
  [ "$(lget sbx-12 .state)" = queued ]
  [ "$(lget sbx-12 .queued_for_slot)" = true ]
  [ "$(lget sbx-12 '[.events[].type] | index("dequeued") == null')" = true ]
  ! grep -q ntfy "$NS_STUB_LOG" 2>/dev/null
}

@test "a non-positive max_runs falls back to 2 with a warning" {
  set_max_runs 0
  run bash -c 'source "$NS_REPO_ROOT/bin/lib/common.sh"; NS_HOME="$NS_REPO_ROOT"; source "$NS_REPO_ROOT/bin/lib/queue.sh"; ns_queue_max'
  assert_output_contains "using 2"
}

# fake_token: a token-shaped test value in tokens/andras-tkcs (never a real token)
fake_token() {
  FAKE_TOKEN="ghp_$(printf 'q%.0s' {1..36})"
  mkdir -p "$NS_CONFIG_DIR/tokens"
  printf '%s\n' "$FAKE_TOKEN" >"$NS_CONFIG_DIR/tokens/andras-tkcs"
  chmod 600 "$NS_CONFIG_DIR/tokens/andras-tkcs"
}

# server_env_clean: the tmux server started by the last command has no token in its environment
server_env_clean() {
  local out
  out=$(tmux show-environment -g)
  [ -n "$out" ]
  run ! grep -q '^GH_TOKEN=' <<<"$out"
  run ! grep -qF "$FAKE_TOKEN" <<<"$out"
}

@test "no tmux server started by ns inherits GH_TOKEN (#96)" {
  # every tmux new-session in bin/ is the one in ns_tmux_start, which drops GH_TOKEN
  run grep -rn 'tmux new-session' "$NS_REPO_ROOT/bin"
  [ "$(grep -c . <<<"$output")" = 1 ]
  assert_output_contains 'env -u GH_TOKEN tmux new-session'
  fake_token
  export GH_TOKEN="$FAKE_TOKEN"
  export TMUX_STUB_SERVER_ENV="$BATS_TEST_TMPDIR/server.env"
  ns new sbx-41 --tier T1 --yes >/dev/null
  server_env_clean
  rm -f "$TMUX_STUB_SERVER_ENV" "$TMUX_STUB_DIR/sbx-41"
  ns-ledger set "$(ledger sbx-41)" '.state="parked"'
  ns resume sbx-41 >/dev/null
  server_env_clean
  rm -f "$TMUX_STUB_SERVER_ENV"
  ns up >/dev/null || true
  [ -f "$TMUX_STUB_DIR/rc" ]
  server_env_clean
  set_max_runs 1
  ns new sbx-42 --tier T1 --yes >/dev/null
  [ "$(lget sbx-42 .state)" = queued ]
  end_session 41
  rm -f "$TMUX_STUB_SERVER_ENV" "$TMUX_STUB_DIR/rc"
  ns dequeue >/dev/null
  [ -f "$TMUX_STUB_DIR/sbx-42" ]
  server_env_clean
  run ! grep -q GH_TOKEN "$TMUX_STUB_DIR/sbx-42"
}

@test "the dequeue pushes carry the run owner's token, the session does not (#96)" {
  fake_token
  set_max_runs 1
  live_run 11
  ns new sbx-12 --tier T1 --yes >/dev/null
  end_session 11
  mkdir -p "$BATS_TEST_TMPDIR/hooks"
  cat >"$BATS_TEST_TMPDIR/hooks/pre-push" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\${GH_TOKEN:-none}" >>"$BATS_TEST_TMPDIR/push.env"
EOS
  chmod +x "$BATS_TEST_TMPDIR/hooks/pre-push"
  git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath "$BATS_TEST_TMPDIR/hooks"
  export TMUX_STUB_SERVER_ENV="$BATS_TEST_TMPDIR/server.env"
  # ns-launch runs ns dequeue without a token
  run env -u GH_TOKEN "$NS_REPO_ROOT/bin/ns" dequeue
  assert_success
  assert_output_contains "1 started"
  assert_output_not_contains "$FAKE_TOKEN"
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
  [ "$(grep -c . "$BATS_TEST_TMPDIR/push.env")" -ge 2 ]
  [ "$(sort -u "$BATS_TEST_TMPDIR/push.env")" = "$FAKE_TOKEN" ]
  run ! grep -q GH_TOKEN "$TMUX_STUB_DIR/sbx-12"
  server_env_clean
}

@test "ns-launch keeps logs/<id> private: directory 700, dequeue.log 600 (#96)" {
  ns new sbx-12 --tier T1 --yes >/dev/null
  rm -f "$TMUX_STUB_DIR/sbx-12"
  # a directory left by an older release with the default umask
  mkdir -p "$NS_CONFIG_DIR/logs/sbx-12"
  chmod 755 "$NS_CONFIG_DIR/logs" "$NS_CONFIG_DIR/logs/sbx-12"
  run bash -c 'umask 022 && exec ns-launch sbx-12 --resume'
  assert_success
  [ "$(stat -c %a "$NS_CONFIG_DIR/logs")" = 700 ]
  [ "$(stat -c %a "$NS_CONFIG_DIR/logs/sbx-12")" = 700 ]
  [ "$(stat -c %a "$NS_CONFIG_DIR/logs/sbx-12/dequeue.log")" = 600 ]
  ns new sbx-13 --tier T1 --yes >/dev/null
  rm -f "$TMUX_STUB_DIR/sbx-13"
  run bash -c 'umask 022 && exec ns-launch sbx-13 --resume'
  assert_success
  [ "$(stat -c %a "$NS_CONFIG_DIR/logs/sbx-13")" = 700 ]
  [ "$(stat -c %a "$NS_CONFIG_DIR/logs/sbx-13/dequeue.log")" = 600 ]
}

@test "a symlinked queue.lock is never truncated (#96)" {
  printf 'keep me\n' >"$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$NS_CONFIG_DIR/queue.lock"
  set_max_runs 1
  live_run 11
  run ns new sbx-12 --tier T1 --yes
  assert_success
  assert_output_contains "queued sbx-12"
  end_session 11
  run ns dequeue
  assert_success
  [ -L "$NS_CONFIG_DIR/queue.lock" ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = "keep me" ]
}

# push_hook: record the GH_TOKEN every git push of the ledger sees in $BATS_TEST_TMPDIR/push.env
push_hook() {
  mkdir -p "$BATS_TEST_TMPDIR/hooks"
  cat >"$BATS_TEST_TMPDIR/hooks/pre-push" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\${GH_TOKEN:-none}" >>"$BATS_TEST_TMPDIR/push.env"
EOS
  chmod +x "$BATS_TEST_TMPDIR/hooks/pre-push"
  git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath "$BATS_TEST_TMPDIR/hooks"
}

@test "a foreign GH_TOKEN never reaches the resume push when the owner has no token file (#96)" {
  ns new sbx-12 --tier T1 --yes >/dev/null
  end_session 12
  push_hook
  OTHER="ghp_$(printf 'o%.0s' {1..36})"
  GH_TOKEN="$OTHER" run ns resume sbx-12
  assert_success
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
  [ -s "$BATS_TEST_TMPDIR/push.env" ]
  run ! grep -qF "$OTHER" "$BATS_TEST_TMPDIR/push.env"
  [ "$(sort -u "$BATS_TEST_TMPDIR/push.env")" = none ]
}

@test "with two owners, each run is pushed with its own owner's token only (#96)" {
  fake_token
  B_TOKEN="ghp_$(printf 'b%.0s' {1..36})"
  printf '%s\n' "$B_TOKEN" >"$NS_CONFIG_DIR/tokens/acme"
  chmod 600 "$NS_CONFIG_DIR/tokens/acme"
  make_remote acme/other
  ns project add acme/other --prefix oth >/dev/null
  ns new sbx-12 --tier T1 --yes >/dev/null
  end_session 12
  push_hook
  GH_TOKEN="$B_TOKEN" run ns resume sbx-12
  assert_success
  [ -s "$BATS_TEST_TMPDIR/push.env" ]
  [ "$(sort -u "$BATS_TEST_TMPDIR/push.env")" = "$FAKE_TOKEN" ]
}

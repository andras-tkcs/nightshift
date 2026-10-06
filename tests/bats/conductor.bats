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

@test "manifest.py lists both phases and phase of a missing id exits 1" {
  run python3 "$NS_REPO_ROOT/bin/lib/manifest.py" phases "$NS_REPO_ROOT/tests/fixtures/plans/two-phase-plan.md"
  assert_success
  [ "$(jq -r '[.[].id] | join(",")' <<<"$output")" = "p1-alpha,p2-beta" ]
  run python3 "$NS_REPO_ROOT/bin/lib/manifest.py" phase "$NS_REPO_ROOT/tests/fixtures/plans/two-phase-plan.md" p2-beta
  assert_success
  [ "$(jq -r .title <<<"$output")" = "Add beta" ]
  run python3 "$NS_REPO_ROOT/bin/lib/manifest.py" phase "$NS_REPO_ROOT/tests/fixtures/plans/two-phase-plan.md" nope
  assert_failure 1
}

@test "--help lists the subcommands and an unknown one exits 2" {
  run ns-conductor --help
  assert_success
  assert_output_contains "  start  "
  assert_output_contains "  park  "
  run ns-conductor frobnicate
  assert_failure 2
  run ns-conductor start nosuch-1 p1-alpha
  assert_failure 1
  assert_output_contains "unknown run nosuch-1"
}

@test "start writes pid file and prompt, sets the phase running" {
  run ns-conductor start sbx-12 p1-alpha
  assert_success
  assert_output_contains "started p1-alpha pid "
  pidf="$NS_CONFIG_DIR/workers/sbx-12--p1-alpha.pid"
  [ -f "$pidf" ]
  grep -q '^run=sbx-12$' "$pidf"
  grep -q '^phase=p1-alpha$' "$pidf"
  prompt="$NS_CONFIG_DIR/logs/sbx-12/p1-alpha.prompt.md"
  grep -q 'id: p1-alpha' "$prompt"
  grep -q 'Add alpha' "$prompt"
  grep -q 'feature/12--p1-alpha' "$prompt"
  ! grep -q 'Review feedback' "$prompt"
  [ "$(pstate p1-alpha state)" = running ]
  [ "$(pstate p1-alpha attempts)" = 1 ]
  [ "$(pstate p1-alpha branch)" = feature/12--p1-alpha ]
  [ "$(lget '.events[-1].type')" = phase-start ]
}

@test "start --feedback puts the feedback in the prompt and rewrites RUN/" {
  printf 'blocking: rename the thing\n' >"$WT/.nightshift/runs/sbx-12/fb.md"
  run ns-conductor start sbx-12 p1-alpha --feedback RUN/fb.md
  assert_success
  grep -q 'Review feedback from round 1' "$NS_CONFIG_DIR/logs/sbx-12/p1-alpha.prompt.md"
  grep -q 'blocking: rename the thing' "$NS_CONFIG_DIR/logs/sbx-12/p1-alpha.prompt.md"
}

@test "start fix-1 works without a manifest entry" {
  printf 'blocking: x\n' >"$BATS_TEST_TMPDIR/fb.md"
  run ns-conductor start sbx-12 fix-1 --feedback "$BATS_TEST_TMPDIR/fb.md"
  assert_success
  grep -q 'Fix review findings' "$NS_CONFIG_DIR/logs/sbx-12/fix-1.prompt.md"
  [ "$(pstate fix-1 state)" = running ]
  run ns-conductor start sbx-12 p9-missing
  assert_failure 1
}

@test "start with the pool full exits 3 and queues the phase" {
  printf 'max_workers: 1\n' >"$NS_CONFIG_DIR/config.yaml"
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/sleeper.sh" run ns-conductor start sbx-12 p1-alpha
  assert_success
  run ns-conductor start sbx-12 p2-beta
  assert_failure 3
  assert_output_contains "queued p2-beta: pool full (1/1)"
  [ "$(pstate p2-beta state)" = queued ]
  run ns-conductor status sbx-12
  assert_success
  assert_output_contains "p1-alpha pid "
}

# live_workers: pid files in the pool whose process is alive
live_workers() {
  local f pid n=0
  for f in "$NS_CONFIG_DIR"/workers/*.pid; do
    [ -f "$f" ] || continue
    pid=$(sed -n 's/^pid=//p' "$f")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then n=$((n + 1)); fi
  done
  printf '%s\n' "$n"
}

# pool_lock_free: nobody holds the pool lock (a worker that inherited it would)
pool_lock_free() {
  flock -n "$NS_CONFIG_DIR/workers/.lock" true
}

@test "two concurrent starts with max_workers 1 start exactly one worker (#10)" {
  printf 'max_workers: 1\n' >"$NS_CONFIG_DIR/config.yaml"
  export CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/sleeper.sh"
  # a lock wait no other test uses, so the waiters below are this test's two starts
  export NS_POOL_LOCK_WAIT=4711
  # the phase worktrees exist already, so both starts get to the spawn at once
  for p in p1-alpha p2-beta; do
    git -C "$WT" worktree add -q -b "feature/12--$p" "$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12--$p" origin/feature/12
    mkdir "$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12--$p/.venv"
  done
  # hold the pool lock: both starts pass the quick unlocked check (0/1) and block on the lock,
  # so only the count under the lock can keep the second worker out
  mkdir -p "$NS_CONFIG_DIR/workers"
  exec {lk}>>"$NS_CONFIG_DIR/workers/.lock"
  flock "$lk"
  for p in p1-alpha p2-beta; do
    (
      exec {lk}>&-
      rc=0
      ns-conductor start sbx-12 "$p" >"$BATS_TEST_TMPDIR/$p.out" 2>&1 || rc=$?
      echo "$rc" >"$BATS_TEST_TMPDIR/$p.rc"
    ) &
  done
  for _ in $(seq 1 150); do
    [ "$(pgrep -c -f "flock -w 4711 9" || true)" -ge 2 ] && break
    sleep 0.2
  done
  [ "$(pgrep -c -f "flock -w 4711 9")" -ge 2 ]
  exec {lk}>&-
  wait
  [ "$(live_workers)" = 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR"/p1-alpha.rc "$BATS_TEST_TMPDIR"/p2-beta.rc | sort | tr '\n' ' ')" = "0 3 " ]
  for p in p1-alpha p2-beta; do
    if [ "$(cat "$BATS_TEST_TMPDIR/$p.rc")" = 3 ]; then
      grep -q "queued $p: pool full (1/1)" "$BATS_TEST_TMPDIR/$p.out"
      [ "$(pstate "$p" state)" = queued ]
    else
      [ "$(pstate "$p" state)" = running ]
    fi
  done
  # no process of the worker's group has the pool lock open
  for f in "$NS_CONFIG_DIR"/workers/*.pid; do
    pid=$(sed -n 's/^pid=//p' "$f")
    for c in $(pgrep -g "$pid"); do
      ! ls -l "/proc/$c/fd" 2>/dev/null | grep -q 'workers/\.lock'
    done
  done
  pool_lock_free
}

@test "the pool lock is released after a start, a queued start and a failed start (#10)" {
  printf 'max_workers: 1\n' >"$NS_CONFIG_DIR/config.yaml"
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/sleeper.sh" run ns-conductor start sbx-12 p1-alpha
  assert_success
  # the live worker must not hold the lock
  pool_lock_free
  run ns-conductor start sbx-12 p2-beta
  assert_failure 3
  pool_lock_free
  run ns-conductor start sbx-12 p1-alpha
  assert_success
  assert_output_contains "p1-alpha already running"
  pool_lock_free
  # a worker that cannot write its pid file: start dies, the lock is free
  kill -KILL -- "-$(sed -n 's/^pid=//p' "$NS_CONFIG_DIR/workers/sbx-12--p1-alpha.pid")"
  rm -f "$NS_CONFIG_DIR"/workers/*.pid
  chmod 555 "$NS_CONFIG_DIR/workers"
  printf 'exit 0\n' >"$BATS_TEST_TMPDIR/quick.sh"
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/quick.sh" run ns-conductor start sbx-12 p2-beta
  chmod 755 "$NS_CONFIG_DIR/workers"
  assert_failure 1
  assert_output_contains "worker for p2-beta did not start"
  pool_lock_free
}

@test "a stale pool lock file does not block a start, and a symlinked one is not truncated (#10)" {
  mkdir -p "$NS_CONFIG_DIR/workers"
  printf 'pid=999999\n' >"$NS_CONFIG_DIR/workers/.lock"
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/sleeper.sh" run ns-conductor start sbx-12 p1-alpha
  assert_success
  rm -f "$NS_CONFIG_DIR/workers/.lock"
  printf 'keep me\n' >"$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$NS_CONFIG_DIR/workers/.lock"
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/sleeper.sh" run ns-conductor start sbx-12 p2-beta
  assert_success
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = "keep me" ]
}

@test "start queues the phase when the pool lock stays busy (#10)" {
  mkdir -p "$NS_CONFIG_DIR/workers"
  exec {lk}>>"$NS_CONFIG_DIR/workers/.lock"
  flock "$lk"
  NS_POOL_LOCK_WAIT=1 run ns-conductor start sbx-12 p1-alpha
  exec {lk}>&-
  assert_failure 3
  assert_output_contains "queued p1-alpha: pool lock busy"
  [ "$(pstate p1-alpha state)" = queued ]
  [ "$(live_workers)" = 0 ]
}

@test "a non-numeric NS_POOL_LOCK_WAIT is refused and starts no worker (#10 review)" {
  NS_POOL_LOCK_WAIT=soon run ns-conductor start sbx-12 p1-alpha
  assert_failure 1
  assert_output_contains "NS_POOL_LOCK_WAIT must be a number of seconds"
  [ "$(live_workers)" = 0 ]
  pool_lock_free
}

@test "a queued phase with no own worker: wait sleeps while the pool is full, returns when a slot frees (#10 review)" {
  printf 'max_workers: 1\n' >"$NS_CONFIG_DIR/config.yaml"
  # another run's worker holds the only slot
  mkdir -p "$NS_CONFIG_DIR/workers"
  setsid bash -c 'echo $$ >"$1"; exec sleep 60' other "$BATS_TEST_TMPDIR/other.pid" &
  for _ in $(seq 1 50); do [ -s "$BATS_TEST_TMPDIR/other.pid" ] && break; sleep 0.1; done
  printf 'pid=%s\n' "$(cat "$BATS_TEST_TMPDIR/other.pid")" >"$NS_CONFIG_DIR/workers/oth-1--p1.pid"
  run ns-conductor start sbx-12 p1-alpha
  assert_failure 3
  [ "$(pstate p1-alpha state)" = queued ]
  t0=$(date +%s)
  run ns-conductor wait sbx-12 --timeout 3
  assert_failure 124
  assert_output_contains "pool full: p1-alpha waits for a slot"
  [ $(($(date +%s) - t0)) -ge 3 ]
  kill "$(cat "$BATS_TEST_TMPDIR/other.pid")"
  run ns-conductor wait sbx-12 --timeout 30
  assert_success
  assert_output_contains "pool slot free"
  rm -f "$NS_CONFIG_DIR/workers/oth-1--p1.pid"
}

@test "wait with no workers and no queued phase still returns at once" {
  run ns-conductor wait sbx-12 --timeout 30
  assert_success
  assert_output_contains "no workers"
}

@test "start with the budget exceeded exits 4" {
  ns-ledger set "$LEDGER" '.budget.limit = 1 | .budget.used = 2'
  run ns-conductor start sbx-12 p1-alpha
  assert_failure 4
  assert_output_contains "budget exceeded"
}

@test "start without auto-mode.ok and a failing claude exits 5 with the hint" {
  unset NS_WORKER_MODE
  CLAUDE_STUB_MODE=fail run ns-conductor start sbx-12 p1-alpha
  assert_failure 5
  assert_output_contains "auto permission mode does not work in headless calls on this machine"
  assert_output_contains "NS_WORKER_MODE=bypassPermissions"
  [ ! -e "$NS_CONFIG_DIR/auto-mode.ok" ]
}

@test "start with a fresh auto-mode.ok skips the check" {
  unset NS_WORKER_MODE
  touch "$NS_CONFIG_DIR/auto-mode.ok"
  run ns-conductor start sbx-12 p1-alpha
  assert_success
  grep -q -- '--permission-mode auto' "$NS_STUB_LOG"
}

@test "check-auto ok creates auto-mode.ok; a denial fails" {
  CLAUDE_STUB_MODE=ok run ns-conductor check-auto
  assert_success
  assert_output_contains "auto mode: ok"
  [ -f "$NS_CONFIG_DIR/auto-mode.ok" ]
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  cat >"$BATS_TEST_TMPDIR/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo '{"type":"result","is_error":false,"result":"ok","permission_denials":[{"tool_name":"Bash"}]}'
EOF
  chmod +x "$BATS_TEST_TMPDIR/fakebin/claude"
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run ns-conductor check-auto
  assert_failure 1
  assert_output_contains "auto mode: not available"
  [ ! -e "$NS_CONFIG_DIR/auto-mode.ok" ]
}

@test "wait reports a finished worker and sets the phase to review" {
  ns-conductor start sbx-12 p1-alpha >/dev/null
  run ns-conductor wait sbx-12 --timeout 30
  assert_success
  [ "$output" = "finished p1-alpha exit 0" ]
  [ "$(pstate p1-alpha state)" = review ]
  [ ! -e "$NS_CONFIG_DIR/workers/sbx-12--p1-alpha.pid" ]
  [ -f "$NS_CONFIG_DIR/logs/sbx-12/done/sbx-12--p1-alpha.pid" ]
  [ "$(cat "$NS_CONFIG_DIR/logs/sbx-12/done/sbx-12--p1-alpha.exit")" = 0 ]
  git -C "$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git" rev-parse --verify -q feature/12--p1-alpha
  grep -q 'PHASE-REPORT p1-alpha' "$NS_CONFIG_DIR/logs/sbx-12/p1-alpha.jsonl"
}

# result_line <is_error> <api_error_status> <text>: a claude -p result line as JSON
result_line() {
  jq -nc --argjson e "$1" --argjson s "$2" --arg t "$3" \
    '{type: "result", subtype: "success", is_error: $e, api_error_status: $s, num_turns: 3, result: $t}'
}

# finish_with <result line>: start p1-alpha with that final result and wait for it
finish_with() {
  CLAUDE_STUB_RESULT_LINE="$1" run ns-conductor start sbx-12 p1-alpha
  assert_success
  run ns-conductor wait sbx-12 --timeout 30
  assert_success
}

# assert_usage_pause <until>: the phase finished on a usage limit that resets at <until>
assert_usage_pause() {
  [ "$output" = "finished p1-alpha usage-limit until $1" ]
  [ "$(lget .budget.paused)" = true ]
  [ "$(lget .budget.paused_until)" = "$1" ]
  [ "$(pstate p1-alpha state)" = pending ]
  [ "$(lget '[.events[] | select(.type == "usage-pause")] | length')" -ge 1 ]
}

# assert_normal_finish: the phase finished normally and went to review
assert_normal_finish() {
  [ "$output" = "finished p1-alpha exit 0" ]
  [ "$(lget '.budget.paused // false')" = false ]
  [ "$(pstate p1-alpha state)" = review ]
  [ "$(lget '[.events[] | select(.type == "usage-pause")] | length')" = 0 ]
}

@test "wait on a usage limit pauses the budget until the reset time and resets the phase" {
  # the shape claude -p prints when a subscription limit ends the turn (NS_NOW is 21:00Z)
  finish_with "$(result_line true 429 "You've hit your session limit · resets 11pm (UTC)")"
  assert_usage_pause 2026-10-02T23:01:00Z
  [ "$(pstate p1-alpha usage_limits)" = 1 ]
}

@test "start refuses with exit 8 while the usage pause lasts and starts after it" {
  finish_with "$(result_line true 429 "You've hit your weekly limit · resets Oct 4, 9:30am (UTC)")"
  assert_usage_pause 2026-10-04T09:31:00Z
  run ns-conductor start sbx-12 p1-alpha
  assert_failure 8
  assert_output_contains "paused until 2026-10-04T09:31:00Z"
  [ "$(pstate p1-alpha state)" = pending ]
  NS_NOW=2026-10-04T09:32:00Z run ns-conductor start sbx-12 p1-alpha
  assert_success
  assert_output_contains "started p1-alpha"
}

@test "an older usage-limit text with an epoch pauses until that epoch" {
  # 1790982000 is 2026-10-02T23:00:00Z
  finish_with '{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1790982000"}'
  assert_usage_pause 2026-10-02T23:01:00Z
}

@test "a usage limit without a reset time backs off 15 minutes, then 30" {
  finish_with "$(result_line true 429 "You've hit your session limit")"
  assert_usage_pause 2026-10-02T21:15:00Z
  ns-ledger set "$LEDGER" '.budget.paused_until = null'
  finish_with "$(result_line true 429 "You've hit your session limit · resets soon")"
  [ "$output" = "finished p1-alpha usage-limit until 2026-10-02T21:30:00Z" ]
  [ "$(pstate p1-alpha usage_limits)" = 2 ]
}

@test "a usage limit that does not reset escalates at once" {
  finish_with "$(result_line true 429 "You've hit your monthly spend limit.")"
  [ "$output" = "finished p1-alpha usage-limit escalate: You've hit your monthly spend limit." ]
  [ "$(lget .budget.paused)" = true ]
  [ "$(lget '.budget.paused_until // "none"')" = none ]
  [ "$(pstate p1-alpha state)" = pending ]
  finish_with "$(result_line true null "You're out of usage credits. Run /usage-credits to keep using Opus or /model to switch models.")"
  assert_output_contains "usage-limit escalate: You're out of usage credits"
}

@test "the fourth usage limit of a phase escalates instead of pausing again" {
  ns-ledger set "$LEDGER" '.phases += [{id: "p1-alpha", title: "a", state: "pending", branch: null, worktree: null, attempts: 3, review_rounds: 0, usage_limits: 3}]'
  finish_with "$(result_line true 429 "You've hit your session limit · resets 11pm (UTC)")"
  [ "$output" = "finished p1-alpha usage-limit escalate: 4 usage limits in this phase" ]
  [ "$(lget '.budget.paused_until // "none"')" = none ]
  [ "$(pstate p1-alpha usage_limits)" = 4 ]
}

@test "a limit text only in errors[] is a usage limit" {
  finish_with '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"errors":["You'"'"'ve hit your session limit · resets 11pm (UTC)"]}'
  assert_usage_pause 2026-10-02T23:01:00Z
}

@test "wait: a successful result that mentions a rate limiter is not a usage limit" {
  finish_with '{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"You'"'"'ve hit your usage limit? No: added the rate limiter; a client over the usage limit gets a 429 (rate limit exceeded).\n\nPHASE-REPORT p1-alpha status=done head=abc"}'
  assert_normal_finish
}

@test "wait: an error result for another reason is not a usage limit" {
  finish_with '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":40,"errors":["Reached maximum number of turns (40)"]}'
  assert_normal_finish
  ns-ledger set "$LEDGER" '.phases |= map(.state = "pending")'
  finish_with "$(result_line true 500 "API Error: 500 Internal server error while the rate limiter test ran; You've hit your limit is not at the start")"
  assert_normal_finish
}

@test "a capacity 429 is retried once after a short backoff, then takes the normal path" {
  finish_with "$(result_line true 429 "Request rejected (429) · this may be a temporary capacity issue.")"
  [ "$output" = "finished p1-alpha transient retry at 2026-10-02T21:01:00Z" ]
  [ "$(lget '.budget.paused // false')" = false ]
  [ "$(pstate p1-alpha state)" = pending ]
  [ "$(pstate p1-alpha not_before)" = 2026-10-02T21:01:00Z ]
  run ns-conductor start sbx-12 p1-alpha
  assert_failure 8
  assert_output_contains "not before 2026-10-02T21:01:00Z"
  export NS_NOW=2026-10-02T21:02:00Z
  finish_with "$(result_line true 429 "Request rejected (429) · this may be a temporary capacity issue.")"
  assert_normal_finish
  [ "$(pstate p1-alpha transient_retries)" = 0 ]
}

@test "a 529 overload is transient, not a usage limit" {
  finish_with "$(result_line true 529 "Repeated 529 Overloaded errors")"
  [ "$output" = "finished p1-alpha transient retry at 2026-10-02T21:01:00Z" ]
  [ "$(lget '.budget.paused // false')" = false ]
}

@test "wait with no workers sleeps until a pending retry is due and prints retry" {
  ns-ledger set "$LEDGER" '.phases += [{id: "p1-alpha", title: "a", state: "pending", branch: null, worktree: null, attempts: 1, review_rounds: 0, not_before: "2026-10-02T21:00:02Z"}]'
  run ns-conductor wait sbx-12 --timeout 1
  assert_failure 124
  assert_output_contains "retry p1-alpha at 2026-10-02T21:00:02Z"
  SECONDS=0
  run ns-conductor wait sbx-12 --timeout 30
  assert_success
  [ "$output" = "retry p1-alpha" ]
  [ "$SECONDS" -ge 1 ]
  ns-ledger set "$LEDGER" '.phases[0].not_before = null'
  run ns-conductor wait sbx-12 --timeout 30
  assert_success
  [ "$output" = "no workers" ]
}

@test "wait with a sleeping worker times out with 124" {
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/sleeper.sh" run ns-conductor start sbx-12 p1-alpha
  assert_success
  run ns-conductor wait sbx-12 --timeout 2
  assert_failure 124
  assert_output_contains "still running: p1-alpha"
}

@test "wait returns 6 when a stop is requested" {
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/sleeper.sh" run ns-conductor start sbx-12 p1-alpha
  ns-ledger set "$LEDGER" '.stop_requested = "stopped"'
  run ns-conductor wait sbx-12 --timeout 2
  assert_failure 6
  assert_output_contains "stop requested"
}

@test "stop kills the process group and resets the phase to pending" {
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/sleeper.sh" run ns-conductor start sbx-12 p1-alpha
  assert_success
  pid=$(sed -n 's/^pid=//p' "$NS_CONFIG_DIR/workers/sbx-12--p1-alpha.pid")
  kill -0 "$pid"
  run ns-conductor stop sbx-12
  assert_success
  ! kill -0 "$pid" 2>/dev/null || [ "$(ps -o stat= -p "$pid" | tr -d ' ' | cut -c1)" = Z ]
  [ ! -e "$NS_CONFIG_DIR/workers/sbx-12--p1-alpha.pid" ]
  [ "$(pstate p1-alpha state)" = pending ]
  run ns-conductor status sbx-12
  [ "$output" = "no workers" ]
}

@test "should-stop follows stop_requested" {
  run ns-conductor should-stop sbx-12
  assert_failure 1
  ns-ledger set "$LEDGER" '.stop_requested = "stopped"'
  run ns-conductor should-stop sbx-12
  assert_success
}

@test "park sets the requested state, clears the flag and pushes" {
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/sleeper.sh" run ns-conductor start sbx-12 p1-alpha
  assert_success
  ns-ledger set "$LEDGER" '.stop_requested = "parked"'
  run ns-conductor park sbx-12
  assert_success
  assert_output_contains "parked sbx-12: end this session now"
  [ "$(lget .state)" = parked ]
  [ "$(lget '.stop_requested')" = null ]
  [ "$(pstate p1-alpha state)" = pending ]
  run ns-conductor status sbx-12
  [ "$output" = "no workers" ]
  remote="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
  [ "$(git -C "$remote" rev-parse plan/sbx-12)" = "$(git -C "$WT" rev-parse HEAD)" ]
}

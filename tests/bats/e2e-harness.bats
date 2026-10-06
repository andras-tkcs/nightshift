#!/usr/bin/env bats
# Offline checks of the end-to-end harness: never calls GitHub or Claude.

load helpers

setup() {
  ns_test_setup
  E2E="$NS_REPO_ROOT/tests/e2e"
  FIX="$NS_REPO_ROOT/tests/fixtures/sandbox-base"
}

@test "run.sh --help exits 0" {
  run "$E2E/run.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *usage* ]]
}

@test "run.sh with an unknown scenario prints usage and exits 2" {
  run "$E2E/run.sh" nope
  [ "$status" -eq 2 ]
  [[ "$output" == *usage* ]]
}

@test "the sandbox repo literal appears once and no other owner/repo literal" {
  run grep -c 'andras-tkcs/nightshift-sandbox' "$E2E/run.sh" "$E2E/lib.sh"
  [[ "$output" == *"run.sh:1"* ]]
  [[ "$output" == *"lib.sh:0"* ]]
  # results.md holds PR URLs of the sandbox (D20), it is data, not harness code
  run grep -rEn --exclude=results.md 'andras-tkcs/|privacyfence/|[A-Za-z0-9-]+/nightshift[A-Za-z0-9._-]*' "$E2E"
  [ "$(wc -l <<<"$output")" -eq 1 ]
  [[ "$output" == *"readonly E2E_REPO=andras-tkcs/nightshift-sandbox"* ]]
}

@test "the rendered fixture profile passes ns profile check" {
  d="$BATS_TEST_TMPDIR/rendered"
  mkdir -p "$d/.claude"
  sed 's|@BASE_BRANCH@|e2e/20261002-1|g' "$FIX/project-profile.yaml.tmpl" >"$d/.claude/project-profile.yaml"
  run ns profile check "$d"
  [ "$status" -eq 0 ]
}

@test "every fixture python file compiles" {
  n=0
  while IFS= read -r f; do
    PYTHONPYCACHEPREFIX="$BATS_TEST_TMPDIR/pyc" python3 -m py_compile "$f"
    n=$((n + 1))
  done < <(find "$FIX" -name '*.py')
  [ "$n" -ge 5 ]
}

@test "cleanup deletes a ledger branch only when it grew from the attempt's base (e2e t2)" {
  # plan/sbx-x1 of an older attempt has unrelated history: compare answers 404
  gh() {
    printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/gh.calls"
    case "$*" in
      *compare/e2e/20261002-3...plan/sbx-x1*) return 1 ;;
      *compare/e2e/20261002-3...feature/x1*) printf 'ahead\n' ;;
      *compare/e2e/20261002-3...fix/sbx-x2*) printf 'identical\n' ;;
      *compare/e2e/20261002-3...fix/sbx-x3*) printf 'diverged\n' ;;
    esac
  }
  E2E_REPO=owner/sandbox
  # shellcheck source=/dev/null
  source "$E2E/lib.sh"
  e2e_gh_delete_attempt_branch e2e/20261002-3 plan/sbx-x1
  e2e_gh_delete_attempt_branch e2e/20261002-3 feature/x1
  e2e_gh_delete_attempt_branch e2e/20261002-3 fix/sbx-x2
  e2e_gh_delete_attempt_branch e2e/20261002-3 fix/sbx-x3
  run grep -c -- '-X DELETE' "$BATS_TEST_TMPDIR/gh.calls"
  [ "$output" -eq 2 ]
  grep -q -- '-X DELETE repos/owner/sandbox/git/refs/heads/feature/x1$' "$BATS_TEST_TMPDIR/gh.calls"
  grep -q -- '-X DELETE repos/owner/sandbox/git/refs/heads/fix/sbx-x2$' "$BATS_TEST_TMPDIR/gh.calls"
}

@test "e2e_conductor_pid gives the pane pid only when it is this run's conductor (e2e resume)" {
  E2E_REPO=owner/sandbox
  # shellcheck source=/dev/null
  source "$E2E/lib.sh"
  export NS_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  env NS_CONFIG_DIR="$NS_CONFIG_DIR" NS_RUN_ID=sbx-1 sleep 60 &
  ours=$!
  env NS_CONFIG_DIR="$BATS_TEST_TMPDIR/other" NS_RUN_ID=sbx-1 sleep 60 &
  other_cfg=$!
  env NS_CONFIG_DIR="$NS_CONFIG_DIR" NS_RUN_ID=sbx-2 sleep 60 &
  other_run=$!
  sleep 0.3
  tmux() { printf '%s\n' "$PANE"; }
  PANE=$ours
  run e2e_conductor_pid sbx-1
  [ "$status" -eq 0 ]
  [ "$output" = "$ours" ]
  PANE=$other_cfg
  run e2e_conductor_pid sbx-1
  [ "$status" -ne 0 ]
  [[ "$output" != "$other_cfg" ]]
  PANE=$other_run
  run e2e_conductor_pid sbx-1
  [ "$status" -ne 0 ]
  PANE=""
  run e2e_conductor_pid sbx-1
  [ "$status" -ne 0 ]
  PANE=abc
  run e2e_conductor_pid sbx-1
  [ "$status" -ne 0 ]
  kill "$ours" "$other_cfg" "$other_run"
}

@test "the resume scenario kills only the pid e2e_conductor_pid vouches for (e2e resume)" {
  run grep -nE 'pkill|killall|kill -9 -|kill -KILL -' "$E2E/scenarios/resume.sh" "$E2E/lib.sh"
  [ "$status" -eq 1 ]
  grep -q 'pid=$(e2e_conductor_pid "$E2E_ID")' "$E2E/scenarios/resume.sh"
}

@test "the fixture README has the typo exactly once" {
  [ "$(grep -o 'recieve' "$FIX/README.md" | wc -l)" -eq 1 ]
}

@test "pool-watch.sh counts live workers from pid files and session-leader processes, read-only (#10)" {
  d="$BATS_TEST_TMPDIR/home"
  mkdir -p "$d/workers"
  # a worker is a session leader (ns-conductor starts it with setsid); its forked child is not
  NS_CONFIG_DIR="$d" setsid bash -c 'echo $$ >"$1"; ( sleep 30; true ) & sleep 30; true' ns-worker "$BATS_TEST_TMPDIR/w.pid" &
  for _ in $(seq 1 50); do [ -s "$BATS_TEST_TMPDIR/w.pid" ] && break; sleep 0.1; done
  live=$(cat "$BATS_TEST_TMPDIR/w.pid")
  printf 'pid=%s\n' "$live" >"$d/workers/app-1--p1.pid"
  printf 'pid=999999\n' >"$d/workers/app-1--p2.pid"
  printf 'pid=%s\n' "$live" >"$d/workers/app-2--p1.pid"
  echo 0 >"$d/workers/app-2--p1.exit"
  before=$(find "$d" -type f -printf '%p %s %T@\n' | sort)
  run "$E2E/pool-watch.sh" --config-dir "$d" --once
  kill -- "-$live" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"live=1 procs=1 max_live=1 max_procs=1 app-1--p1"* ]]
  [[ "$output" == *"max live workers seen: 1 (procs: 1)"* ]]
  [[ "$output" != *"No such file"* ]]
  [ "$(find "$d" -type f -printf '%p %s %T@\n' | sort)" = "$before" ]
  run "$E2E/pool-watch.sh" --interval 0
  [ "$status" -eq 2 ]
}

@test "pool-watch.sh fails when a live pid file has no ns-worker process for that home (#10)" {
  d="$BATS_TEST_TMPDIR/home"
  mkdir -p "$d/workers"
  # a live process, but not an ns-worker of this home: the cross-check must not stay silent at 0
  sleep 30 &
  printf 'pid=%s\n' "$!" >"$d/workers/app-1--p1.pid"
  run "$E2E/pool-watch.sh" --config-dir "$d" --once
  kill "$!" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" == *"live=1 procs=0"* ]]
  [[ "$output" == *"no ns-worker process"* ]]
}

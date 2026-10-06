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

# e2e_runs_fixture: two runs in runs.yaml; sbx-1 has a ledger in its worktree, sbx-2 has none,
# and a stray notes.md of sbx-1 sits in an older directory under E2E_ROOT
e2e_runs_fixture() {
  E2E_ROOT="$BATS_TEST_TMPDIR/root"
  RUN1="$E2E_ROOT/coding/worktrees/sandbox-sbx-1/.nightshift/runs/sbx-1"
  mkdir -p "$RUN1" "$E2E_ROOT/aaa-old/.nightshift/runs/sbx-1" "$E2E_ROOT/coding/worktrees/sandbox-sbx-2"
  printf 'id: sbx-1\n' >"$RUN1/ledger.yaml"
  printf '1. stray\n2. stray\n' >"$E2E_ROOT/aaa-old/.nightshift/runs/sbx-1/notes.md"
  cat >"$NS_CONFIG_DIR/runs.yaml" <<YAML
runs:
  - id: sbx-1
    worktree: $E2E_ROOT/coding/worktrees/sandbox-sbx-1
  - id: sbx-2
    worktree: $E2E_ROOT/coding/worktrees/sandbox-sbx-2
YAML
}

@test "e2e_run_dir resolves RUN/ from the worktree that holds the run's ledger (ns-71)" {
  E2E_REPO=owner/sandbox
  # shellcheck source=/dev/null
  source "$E2E/lib.sh"
  e2e_runs_fixture
  run e2e_run_dir sbx-1
  [ "$status" -eq 0 ]
  [ "$output" = "$RUN1" ]
  # no ledger in the worktree, or an unknown run: no directory
  run e2e_run_dir sbx-2
  [ "$status" -ne 0 ]
  run e2e_run_dir sbx-9
  [ "$status" -ne 0 ]
}

@test "t1_notes_match reads notes.md of the run's own worktree, not the first copy find sees (ns-71)" {
  E2E_REPO=owner/sandbox
  # shellcheck source=/dev/null
  source "$E2E/lib.sh"
  # shellcheck source=/dev/null
  source "$E2E/scenarios/t1.sh"
  e2e_runs_fixture
  # the ledger has no note events
  e2e_ledger_has() { return 1; }
  run t1_notes_match sbx-1
  [ "$status" -eq 0 ]
  printf '1. real\n' >"$RUN1/notes.md"
  run t1_notes_match sbx-1
  [ "$status" -ne 0 ]
  # a run whose ledger cannot be found is a failure, not a pass
  run t1_notes_match sbx-2
  [ "$status" -ne 0 ]
}

@test "t1_no_denial matches the auto mode classifier denial text of Claude Code (ns-71)" {
  E2E_REPO=owner/sandbox
  # shellcheck source=/dev/null
  source "$E2E/lib.sh"
  # shellcheck source=/dev/null
  source "$E2E/scenarios/t1.sh"
  mkdir -p "$NS_CONFIG_DIR/logs/sbx-1"
  log="$NS_CONFIG_DIR/logs/sbx-1/conductor.jsonl"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}\n' >"$log"
  run t1_no_denial sbx-1
  [ "$status" -eq 0 ]
  printf '{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: pushes to main"}]}}\n' >>"$log"
  run t1_no_denial sbx-1
  [ "$status" -ne 0 ]
  printf '{"type":"result","result":"Auto mode could not evaluate this action and is blocking it for safety"}\n' >"$log"
  run t1_no_denial sbx-1
  [ "$status" -ne 0 ]
}

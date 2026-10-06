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

@test "stack scenario: only run PRs whose chain belongs to its base branch are leftovers, by the library's rules (sprint #122, review S2, N5)" {
  # shellcheck source=/dev/null
  source "$E2E/scenarios/stack.sh"
  local open plans closed
  # old e2e PRs on other bases; a two-PR stack on this base; x9 on a closed run branch whose PR targeted
  # this base; x3 on a closed run branch whose PR targeted an old base; x4 on a run branch with no PR found
  # (unknown: counts, conservative); a non-run PR and a run PR without a plan branch on this base
  open='[
 {"number":1,"head":"fix/sbx-x1","base":"e2e/20261002-1","createdAt":"2026-10-02T10:00:00Z"},
 {"number":2,"head":"fix/sbx-x6","base":"fix/sbx-x1","createdAt":"2026-10-02T11:00:00Z"},
 {"number":3,"head":"fix/sbx-x7","base":"e2e/20261006-1","createdAt":"2026-10-06T10:00:00Z"},
 {"number":4,"head":"fix/sbx-x8","base":"fix/sbx-x7","createdAt":"2026-10-06T11:00:00Z"},
 {"number":5,"head":"fix/sbx-x9","base":"fix/sbx-x5","createdAt":"2026-10-06T11:00:00Z"},
 {"number":6,"head":"fix/sbx-x3","base":"fix/sbx-x2","createdAt":"2026-10-06T11:00:00Z"},
 {"number":7,"head":"fix/sbx-x4","base":"fix/sbx-x0","createdAt":"2026-10-06T11:00:00Z"},
 {"number":8,"head":"dependabot/x","base":"e2e/20261006-1","createdAt":"2026-10-06T11:00:00Z"},
 {"number":9,"head":"fix/sbx-x10","base":"e2e/20261006-1","createdAt":"2026-10-06T11:00:00Z"}
]'
  plans=$(printf '%s\n' sbx-x1 sbx-x3 sbx-x4 sbx-x6 sbx-x7 sbx-x8 sbx-x9)
  closed='[
 {"number":20,"headRefName":"fix/sbx-x5","baseRefName":"e2e/20261006-1","closedAt":"2026-10-06T12:00:00Z","merged":false},
 {"number":21,"headRefName":"fix/sbx-x2","baseRefName":"e2e/20261002-3","closedAt":"2026-10-06T12:00:00Z","merged":false}
]'
  run stack_leftovers "$open" "$plans" e2e/20261006-1 sbx "fix/{slug}" "feature/{n}" "" "$closed"
  [ "$status" -eq 0 ]
  [ "$output" = "fix/sbx-x7 fix/sbx-x8 fix/sbx-x9 fix/sbx-x4" ]
  run stack_leftovers "$open" "$plans" e2e/20261002-1 sbx "fix/{slug}" "feature/{n}" "" "$closed"
  [ "$output" = "fix/sbx-x1 fix/sbx-x6 fix/sbx-x4" ]
}

@test "stack scenario: the second PR's own extra files pass, a repeated change of the first PR fails (sprint #122, check 2)" {
  # shellcheck source=/dev/null
  source "$E2E/scenarios/stack.sh"
  local d="$BATS_TEST_TMPDIR/diffs"
  mkdir -p "$d"
  printf '%s\n' 'diff --git a/README.md b/README.md' '--- a/README.md' '+++ b/README.md' '@@ -1 +1 @@' \
    '-It helps you recieve text' '+It helps you receive text' >"$d/1"
  # an agent's own extras: a README pointer and a test with a common import line
  printf '%s\n' 'diff --git a/NOTES.md b/NOTES.md' '--- /dev/null' '+++ b/NOTES.md' '@@ -0,0 +1 @@' '+second run' \
    'diff --git a/README.md b/README.md' '--- a/README.md' '+++ b/README.md' '@@ -15 +15,2 @@' '+See NOTES.md' >"$d/2"
  # the first PR's change leaked into the second
  printf '%s\n' 'diff --git a/NOTES.md b/NOTES.md' '--- /dev/null' '+++ b/NOTES.md' '@@ -0,0 +1 @@' '+second run' \
    'diff --git a/README.md b/README.md' '--- a/README.md' '+++ b/README.md' '@@ -1 +1 @@' \
    '-It helps you recieve text' '+It helps you receive text' >"$d/3"
  e2e_pr_url() { printf '%s\n' "$1"; }
  gh() { cat "$d/$3"; }
  e2e_log() { :; }
  run stack_diff_is_own 1 2
  [ "$status" -eq 0 ]
  run stack_diff_is_own 1 3
  [ "$status" -ne 0 ]
  run stack_diff_is_own 1 1
  [ "$status" -ne 0 ]
}

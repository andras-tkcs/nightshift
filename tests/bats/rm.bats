#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  export GH_STUB_RESPONSES="$NS_REPO_ROOT/tests/fixtures/gh-stub/responses/gc"
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
  REMOTE="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T1 --yes >/dev/null
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  FWT="$WT--fix"
  LEDGER="$WT/.nightshift/runs/sbx-12/ledger.yaml"
  PROJ="$(dirname "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)")"
  DESK="$NS_DESK_DIR/nightshift-sandbox"
  rm -f "$TMUX_STUB_DIR/sbx-12"

  # a finished run: code branch with its own worktree, one phase branch, a desk folder, a session
  git -C "$PROJ" worktree add -q -b feature/sbx-12 "$FWT" origin/main
  git -C "$FWT" push -q -u origin feature/sbx-12
  git -C "$PROJ" push -q origin origin/main:refs/heads/phase/sbx-12--p1
  git -C "$PROJ" fetch -q origin
  git -C "$PROJ" branch -q phase/sbx-12--p1 origin/main
  ns-ledger set "$LEDGER" '.feature_branch="feature/sbx-12" | .pr="https://github.com/andras-tkcs/nightshift-sandbox/pull/101" | .phases=[{"id":"p1","title":"t","state":"merged","branch":"phase/sbx-12--p1","worktree":null,"attempts":1,"review_rounds":0}]'
  ns-ledger set "$LEDGER" '.state="parked"'
  ns-ledger checkpoint "$LEDGER" --push
  mkdir -p "$DESK/runs/sbx-12"
  printf 'plan\n' >"$DESK/runs/sbx-12/plan.md"
  : >"$TMUX_STUB_DIR/sbx-12"
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }
lget() { ns-ledger get "$LEDGER" "$1"; }
snapshot() {
  {
    find "$NS_CODING_DIR" "$NS_DESK_DIR" "$TMUX_STUB_DIR" 2>/dev/null | sort
    git ls-remote "$REMOTE"
    git -C "$PROJ" branch --list
  } >"$1"
}
set_pr() {
  ns-ledger set "$LEDGER" ".pr=\"https://github.com/andras-tkcs/nightshift-sandbox/pull/$1\""
  ns-ledger checkpoint "$LEDGER" --push
}

@test "ns rm removes a parked run's branches, worktrees and desk and archives it" {
  run ns rm sbx-12 --yes --remote
  assert_success
  [ ! -e "$WT" ]
  [ ! -e "$FWT" ]
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
  [ -z "$(git -C "$PROJ" branch --list 'plan/sbx-12' 'feature/sbx-12' 'phase/sbx-12--p1')" ]
  [ -z "$(git ls-remote --heads "$REMOTE" 'plan/sbx-12' 'phase/sbx-12--p1' 'feature/sbx-12')" ]
  [ ! -e "$DESK/runs/sbx-12" ]
  [ -f "$DESK/archive/2026-10/sbx-12/plan.md" ]
  run ns ls
  assert_output_not_contains "sbx-12"
  run ns ls --all
  assert_output_contains "sbx-12"
}

@test "ns purge is an alias of ns rm" {
  run ns purge sbx-12 --yes
  assert_success
  [ ! -e "$WT" ]
  [ ! -e "$FWT" ]
}

@test "ns rm refuses a live run and points to ns stop" {
  ns-ledger set "$LEDGER" '.state="running"'
  ns-ledger checkpoint "$LEDGER" --push
  run ns rm sbx-12 --yes
  assert_failure
  assert_output_contains "ns stop"
  [ -d "$WT" ]
  [ -d "$FWT" ]
  [ -d "$DESK/runs/sbx-12" ]
}

@test "ns rm --dry-run lists items and changes nothing" {
  snapshot "$BATS_TEST_TMPDIR/before"
  run ns rm sbx-12 --dry-run --remote
  assert_success
  assert_output_contains "would remove worktree $WT"
  assert_output_contains "would remove worktree $FWT"
  assert_output_contains "would remove branch plan/sbx-12"
  snapshot "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  [ "$(lget .state)" = parked ]
}

@test "ns rm refuses uncommitted work without --force" {
  printf 'x\n' >"$FWT/scratch.txt"
  run ns rm sbx-12 --yes
  assert_failure
  assert_output_contains "uncommitted changes"
  [ -d "$FWT" ]
  [ -d "$WT" ]
  run ns rm sbx-12 --yes --force
  assert_success
  [ ! -e "$FWT" ]
}

@test "ns rm keeps remote branches without --remote" {
  run ns rm sbx-12 --yes
  assert_success
  [ ! -e "$WT" ]
  [ -z "$(git -C "$PROJ" branch --list 'feature/sbx-12' 'phase/sbx-12--p1')" ]
  [ -n "$(git ls-remote --heads "$REMOTE" 'plan/sbx-12')" ]
  [ -n "$(git ls-remote --heads "$REMOTE" 'phase/sbx-12--p1')" ]
  [ -n "$(git ls-remote --heads "$REMOTE" 'feature/sbx-12')" ]
}

@test "ns rm --yes --remote leaves an open PR open when unsaved work refuses the run" {
  set_pr 101
  printf 'x\n' >"$FWT/scratch.txt"
  run ns rm sbx-12 --yes --remote
  assert_failure
  assert_output_contains "uncommitted changes"
  assert_output_not_contains "closed PR"
  [ -d "$FWT" ]
  [ -d "$WT" ]
  if [ -f "$GH_STUB_LOG" ]; then ! grep -q 'pr close' "$GH_STUB_LOG"; fi
}

@test "ns rm --all-stopped removes parked runs only" {
  "$NS_REPO_ROOT/bin/ns" new sbx-13 --tier T1 --yes >/dev/null
  WT2="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-13"
  ns-ledger set "$WT2/.nightshift/runs/sbx-13/ledger.yaml" '.state="running"'
  run ns rm --all-stopped --yes
  assert_success
  [ ! -e "$WT" ]
  [ -d "$WT2" ]
}

@test "ns rm keeps the run when the confirmation is declined" {
  run bash -c "printf 'n\\n' | '$NS_REPO_ROOT/bin/ns' rm sbx-12"
  assert_output_contains "kept sbx-12"
  [ -d "$WT" ]
}

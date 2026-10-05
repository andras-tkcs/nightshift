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
  BARE="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T1 --yes >/dev/null
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  LEDGER="$WT/.nightshift/runs/sbx-12/ledger.yaml"
  PROJ="$(dirname "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)")"
  # ns new left a stub tmux session behind; start from "no session"
  rm -f "$TMUX_STUB_DIR/sbx-12"
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }
lget() { ns-ledger get "$LEDGER" "$1"; }

@test "a parked run resumes: session, state, event and push" {
  ns-ledger set "$LEDGER" '.state="parked"'
  run ns resume sbx-12
  assert_success
  [ "$output" = "resumed sbx-12" ]
  [ "$(lget .state)" = running ]
  [ "$(lget '.events[-1].type')" = resumed ]
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
  grep -q '^CMD exec .*ns-launch sbx-12 --resume$' "$TMUX_STUB_DIR/sbx-12"
  git -C "$BARE" log plan/sbx-12 --format=%s | grep -q 'ns-ledger: sbx-12 running'
}

@test "a running run with a session is already running" {
  ns-ledger set "$LEDGER" '.state="running"'
  : >"$TMUX_STUB_DIR/sbx-12"
  run ns resume sbx-12
  assert_success
  [ "$output" = "sbx-12 is already running" ]
}

@test "a parked run with a stale session gets a new session" {
  ns-ledger set "$LEDGER" '.state="parked"'
  printf 'CMD stale\n' >"$TMUX_STUB_DIR/sbx-12"
  run ns resume sbx-12
  assert_success
  grep -q 'ns-launch sbx-12 --resume' "$TMUX_STUB_DIR/sbx-12"
  ! grep -q 'CMD stale' "$TMUX_STUB_DIR/sbx-12"
}

@test "an unknown run exits 1" {
  run ns resume sbx-99
  assert_failure 1
  assert_output_contains "unknown run sbx-99"
}

@test "a deleted worktree is rebuilt from the local branch" {
  ns-ledger set "$LEDGER" '.state="parked"'
  ns-ledger checkpoint "$LEDGER" --push
  rm -rf "$WT"
  run ns resume sbx-12
  assert_success
  [ -f "$LEDGER" ]
  [ "$(lget .state)" = running ]
}

@test "a deleted worktree and local branch are rebuilt from origin" {
  ns-ledger set "$LEDGER" '.state="parked"'
  ns-ledger checkpoint "$LEDGER" --push
  git -C "$PROJ" worktree remove --force "$WT"
  git -C "$PROJ" branch -D plan/sbx-12 >/dev/null
  run ns resume sbx-12
  assert_success
  [ -f "$LEDGER" ]
  [ "$(lget .state)" = running ]
}

@test "a branch that is gone locally and remotely exits 1" {
  git -C "$PROJ" worktree remove --force "$WT"
  git -C "$PROJ" branch -D plan/sbx-12 >/dev/null
  git -C "$BARE" branch -D plan/sbx-12 >/dev/null
  git -C "$PROJ" update-ref -d refs/remotes/origin/plan/sbx-12
  run ns resume sbx-12
  assert_failure 1
  assert_output_contains "cannot rebuild sbx-12: branch plan/sbx-12 is on neither this machine nor origin"
}

@test "a done run has nothing to resume" {
  ns-ledger set "$LEDGER" '.state="done"'
  run ns resume sbx-12
  assert_success
  [ "$output" = "sbx-12 is done; nothing to resume" ]
  [ ! -f "$TMUX_STUB_DIR/sbx-12" ]
}

@test "a run at a gate waits for the owner" {
  ns-ledger set "$LEDGER" '.state="waiting" | .gate="1"'
  run ns resume sbx-12
  assert_success
  [ "$output" = "sbx-12 waits for the owner at gate 1: edit the desk documents, then ns approve sbx-12" ]
  [ ! -f "$TMUX_STUB_DIR/sbx-12" ]
}

@test "a phase whose trailer is on the feature branch becomes merged" {
  git -C "$WT" branch feature/12 origin/main
  git -C "$WT" worktree add -q "$BATS_TEST_TMPDIR/featwt" feature/12
  git -C "$BATS_TEST_TMPDIR/featwt" commit -q --allow-empty -m "Merge phase p1-alpha" -m "Plan-Phase: p1-alpha"
  git -C "$BATS_TEST_TMPDIR/featwt" push -q origin feature/12
  ns-ledger set "$LEDGER" '.state="parked" | .feature_branch="feature/12" | .phases=[
    {id:"p1-alpha",title:"a",state:"running",branch:null,worktree:null,attempts:1,review_rounds:0},
    {id:"p2-beta",title:"b",state:"running",branch:null,worktree:null,attempts:1,review_rounds:0}]'
  run ns resume sbx-12
  assert_success
  [ "$(lget '.phases[0].state')" = merged ]
  [ "$(lget '.phases[1].state')" = pending ]
  lget '.events[].note' | grep -q 'reconciled p1-alpha as merged'
}

@test "--all resumes parked and crashed runs and leaves waiting and done alone" {
  ns new sbx-13 --tier T1 --yes >/dev/null
  ns new sbx-14 --tier T1 --yes >/dev/null
  ns new sbx-15 --tier T1 --yes >/dev/null
  local n
  for n in 13 14 15; do rm -f "$TMUX_STUB_DIR/sbx-$n"; done
  ns-ledger set "$LEDGER" '.state="parked"'
  ns-ledger set "$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-13/.nightshift/runs/sbx-13/ledger.yaml" '.state="running"'
  ns-ledger set "$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-14/.nightshift/runs/sbx-14/ledger.yaml" '.state="waiting" | .gate="1"'
  ns-ledger set "$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-15/.nightshift/runs/sbx-15/ledger.yaml" '.state="done"'
  run ns resume --all
  assert_success
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
  [ -f "$TMUX_STUB_DIR/sbx-13" ]
  [ ! -f "$TMUX_STUB_DIR/sbx-14" ]
  [ ! -f "$TMUX_STUB_DIR/sbx-15" ]
}

@test "resume launches the release the run started on (ns-46)" {
  mkdir -p "$BATS_TEST_TMPDIR/opt"
  ln -s "$NS_REPO_ROOT" "$BATS_TEST_TMPDIR/opt/v0.0.9"
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  ns-ledger set "$LEDGER" '.state="parked" | .release="v0.0.9"'
  run ns resume sbx-12
  assert_success
  grep -q "$BATS_TEST_TMPDIR/opt/v0.0.9/bin/ns-launch sbx-12 --resume" "$TMUX_STUB_DIR/sbx-12"
}

@test "resume dies when the pinned release is gone (ns-46)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$NS_OPT"
  ns-ledger set "$LEDGER" '.state="parked" | .release="v0.0.1"'
  run ns resume sbx-12
  assert_failure
  assert_output_contains "v0.0.1"
}

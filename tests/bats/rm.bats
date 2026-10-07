#!/usr/bin/env bats

load helpers

fixture_vars() {
  FIX="$BATS_TEST_TMPDIR/fixture"
  REMOTE="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  FWT="$WT--fix"
  LEDGER="$WT/.nightshift/runs/sbx-12/ledger.yaml"
  DESK="$NS_DESK_DIR/nightshift-sandbox"
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
git:
  feature_branch: "feature/{slug}"
  phase_branch: "phase/{slug}--{phase}"
stacks: [python]
EOF
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T1 --yes >/dev/null
  PROJ="$(dirname "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)")"
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

setup() {
  ns_test_setup
  export GH_STUB_RESPONSES="$NS_REPO_ROOT/tests/fixtures/gh-stub/responses/gc"
  ns_cached_fixture fixture_build
  fixture_vars
  PROJ="$(dirname "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)")"
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
  set_pr 103
  printf 'x\n' >"$FWT/scratch.txt"
  run ns rm sbx-12 --yes --remote
  assert_failure
  assert_output_contains "uncommitted changes"
  assert_output_not_contains "closed PR"
  [ -d "$FWT" ]
  [ -d "$WT" ]
  ! grep -q 'pr close' "$GH_STUB_LOG"
}

@test "ns rm --yes --remote closes an open PR when the run is clean" {
  set_pr 103
  run ns rm sbx-12 --yes --remote
  assert_success
  assert_output_contains "closed PR"
  grep -q 'pr close' "$GH_STUB_LOG"
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

@test "ns new on an archived id says it is archived and names ns rm --forget" {
  ns rm sbx-12 --yes >/dev/null
  run ns new sbx-12 --tier T1 --yes
  assert_failure
  assert_output_contains "archived"
  assert_output_contains "ns rm sbx-12 --forget --remote"
  assert_output_contains "--dry-run"
  assert_output_contains "closes an open PR"
  assert_output_not_contains "ns resume"
}

@test "ns rm --remote on an already removed run reads origin/plan and deletes the remote branches" {
  ns rm sbx-12 --yes >/dev/null
  [ ! -e "$WT" ]
  [ -n "$(git ls-remote --heads "$REMOTE" 'plan/sbx-12')" ]
  run ns rm sbx-12 --yes --remote
  assert_success
  assert_output_contains "remove remote-branch origin/plan/sbx-12"
  [ -z "$(git ls-remote --heads "$REMOTE" 'plan/sbx-12' 'phase/sbx-12--p1' 'feature/sbx-12')" ]
  run ns ls --all
  assert_output_contains "sbx-12"
}

@test "ns rm --forget without --remote refuses while plan/<id> is on origin" {
  snapshot "$BATS_TEST_TMPDIR/before"
  run ns rm sbx-12 --forget --yes
  assert_failure
  assert_output_contains "plan/sbx-12 is still on origin"
  assert_output_contains "--remote"
  snapshot "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  ns ls --all | grep -q sbx-12
  # also after a plain ns rm: the entry stays until the branch is gone
  ns rm sbx-12 --yes >/dev/null
  run ns rm sbx-12 --forget --yes
  assert_failure
  assert_output_contains "plan/sbx-12 is still on origin"
  ns ls --all | grep -q sbx-12
}

@test "ns rm --forget --remote on a removed run frees the id and ns new works afterwards" {
  ns rm sbx-12 --yes >/dev/null
  run ns rm sbx-12 --forget --remote --yes
  assert_success
  assert_output_contains "forgot sbx-12"
  [ -z "$(git ls-remote --heads "$REMOTE" 'plan/sbx-12' 'phase/sbx-12--p1' 'feature/sbx-12')" ]
  run ns ls --all
  assert_output_not_contains "sbx-12"
  run ns new sbx-12 --tier T1 --yes
  assert_success
  [ -f "$LEDGER" ]
  [ "$(lget .state)" != parked ]
}

@test "ns rm --forget --remote removes and forgets a parked run in one call" {
  set_pr 103
  run ns rm sbx-12 --forget --remote --yes
  assert_success
  assert_output_contains "closed PR"
  assert_output_contains "forgot sbx-12"
  [ ! -e "$WT" ]
  [ -z "$(git ls-remote --heads "$REMOTE" 'plan/sbx-12')" ]
  run ns new sbx-12 --tier T1 --yes
  assert_success
}

@test "ns rm --forget refuses a live run" {
  ns-ledger set "$LEDGER" '.state="running"'
  ns-ledger checkpoint "$LEDGER" --push
  run ns rm sbx-12 --forget --remote --yes
  assert_failure
  assert_output_contains "ns stop"
  [ -d "$WT" ]
  [ -n "$(git ls-remote --heads "$REMOTE" 'plan/sbx-12')" ]
  ns ls --all | grep -q sbx-12
}

@test "ns rm --forget --remote --dry-run prints what it would do and changes nothing" {
  ns rm sbx-12 --yes >/dev/null
  cp "$NS_CONFIG_DIR/runs.yaml" "$BATS_TEST_TMPDIR/runs.before"
  snapshot "$BATS_TEST_TMPDIR/before"
  run ns rm sbx-12 --forget --remote --dry-run
  assert_success
  assert_output_contains "would remove remote-branch origin/plan/sbx-12"
  assert_output_contains "would forget sbx-12"
  snapshot "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/runs.before" "$NS_CONFIG_DIR/runs.yaml"
}

@test "ns rm --all-stopped does not take --forget" {
  run ns rm --all-stopped --forget --yes
  assert_failure
  [ -d "$WT" ]
}

@test "ns rm --help mentions --forget" {
  run ns rm --help
  assert_success
  assert_output_contains "--forget"
}

@test "ns rm --forget without --remote frees the id once plan/<id> is gone from origin" {
  ns rm sbx-12 --yes --remote >/dev/null
  [ -z "$(git ls-remote --heads "$REMOTE" 'plan/sbx-12')" ]
  run ns rm sbx-12 --forget --yes
  assert_success
  assert_output_contains "forgot sbx-12"
  run ns ls --all
  assert_output_not_contains "sbx-12"
}

# an archived run that was resumed has its worktree and ledger back: they decide again
archive_and_resume_running() {
  ns rm sbx-12 --yes >/dev/null
  [ ! -e "$WT" ]
  ns resume sbx-12 >/dev/null 2>&1 || true
  [ -f "$LEDGER" ]
  ns-ledger set "$LEDGER" '.state="running"'
  : >"$TMUX_STUB_DIR/sbx-12"
}

@test "ns rm refuses an archived run that was resumed and is running" {
  archive_and_resume_running
  run ns rm sbx-12 --yes
  assert_failure
  assert_output_contains "ns stop"
  [ -d "$WT" ]
  [ -e "$TMUX_STUB_DIR/sbx-12" ]
}

@test "ns rm --forget refuses an archived run that was resumed and is running" {
  archive_and_resume_running
  run ns rm sbx-12 --forget --remote --yes
  assert_failure
  assert_output_contains "ns stop"
  [ -d "$WT" ]
  [ -n "$(git ls-remote --heads "$REMOTE" 'plan/sbx-12')" ]
  ns ls --all | grep -q sbx-12
}

@test "ns rm refuses an archived run whose tmux session is alive" {
  archive_and_resume_running
  ns-ledger set "$LEDGER" '.state="parked"'
  ns-ledger checkpoint "$LEDGER" --push
  run ns rm sbx-12 --yes
  assert_failure
  assert_output_contains "tmux session"
  [ -d "$WT" ]
}

@test "ns rm --forget keeps the entry when the removal partly failed" {
  git -C "$PROJ" worktree lock "$WT"
  run ns rm sbx-12 --forget --remote --yes
  assert_failure
  assert_output_contains "kept the run in runs.yaml"
  assert_output_not_contains "forgot sbx-12"
  [ -d "$WT" ]
  ns ls --all | grep -q sbx-12
}

@test "ns rm --remote deletes only the run's own branches named in the ledger" {
  git -C "$PROJ" push -q origin origin/main:refs/heads/feature/sbx-1 origin/main:refs/heads/phase/sbx-1--p1 origin/main:refs/heads/-x
  ns-ledger set "$LEDGER" '.feature_branch="feature/sbx-1" | .phases=[{"id":"p1","title":"t","state":"merged","branch":"phase/sbx-1--p1","worktree":null,"attempts":1,"review_rounds":0},{"id":"p2","title":"t","state":"merged","branch":"-x","worktree":null,"attempts":1,"review_rounds":0}]'
  ns-ledger checkpoint "$LEDGER" --push
  ns rm sbx-12 --yes >/dev/null
  run ns rm sbx-12 --remote --yes
  assert_success
  assert_output_contains "not a branch of sbx-12"
  [ -z "$(git ls-remote --heads "$REMOTE" 'plan/sbx-12')" ]
  [ -n "$(git ls-remote --heads "$REMOTE" 'feature/sbx-1')" ]
  [ -n "$(git ls-remote --heads "$REMOTE" 'phase/sbx-1--p1')" ]
  [ -n "$(git ls-remote "$REMOTE" 'refs/heads/-x')" ]
}

@test "ns rm --forget --remote refuses when origin cannot be fetched" {
  set_pr 103
  ns rm sbx-12 --yes >/dev/null
  git -C "$PROJ" update-ref -d refs/remotes/origin/plan/sbx-12
  git -C "$PROJ" config remote.origin.url /nonexistent-for-fetch
  git -C "$PROJ" config remote.origin.pushurl "$REMOTE"
  run ns rm sbx-12 --forget --remote --yes
  assert_failure
  assert_output_contains "cannot"
  assert_output_not_contains "forgot sbx-12"
  ! grep -q 'pr close' "$GH_STUB_LOG"
  [ -n "$(git ls-remote --heads "$REMOTE" 'feature/sbx-12')" ]
  ns ls --all | grep -q sbx-12
}

@test "ns rm --forget is not blocked by another branch ending in plan/<id>" {
  git -C "$PROJ" push -q origin origin/main:refs/heads/old/plan/sbx-12
  ns rm sbx-12 --remote --yes >/dev/null
  run ns rm sbx-12 --forget --yes
  assert_success
  assert_output_contains "forgot sbx-12"
  [ -n "$(git ls-remote "$REMOTE" 'refs/heads/old/plan/sbx-12')" ]
}

@test "a forgotten id that is reused and removed again keeps both desk archives" {
  ns rm sbx-12 --forget --remote --yes >/dev/null
  ns new sbx-12 --tier T1 --yes >/dev/null
  ns-ledger set "$LEDGER" '.state="parked"'
  ns-ledger checkpoint "$LEDGER" --push
  mkdir -p "$DESK/runs/sbx-12"
  printf 'second\n' >"$DESK/runs/sbx-12/plan.md"
  run ns rm sbx-12 --yes
  assert_success
  [ "$(cat "$DESK/archive/2026-10/sbx-12/plan.md")" = plan ]
  grep -qx second "$DESK/archive/2026-10/"sbx-12-*/plan.md
}

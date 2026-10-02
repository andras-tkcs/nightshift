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
  ns-ledger set "$LEDGER" '.state="done"'
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

@test "a done run with a merged PR is cleaned up and archived" {
  run ns gc
  assert_success
  assert_output_contains "remove worktree $WT"
  assert_output_contains "remove worktree $FWT"
  assert_output_contains "remove branch plan/sbx-12"
  assert_output_contains "remove remote-branch origin/plan/sbx-12"
  assert_output_contains "remove tmux sbx-12"
  assert_output_contains "ns gc: freed"
  [ ! -e "$WT" ]
  [ ! -e "$FWT" ]
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
  [ -z "$(git -C "$PROJ" branch --list 'plan/sbx-12' 'feature/sbx-12' 'phase/sbx-12--p1')" ]
  [ -z "$(git ls-remote --heads "$REMOTE" 'plan/sbx-12' 'phase/sbx-12--p1')" ]
  [ -d "$PROJ/.git" ]
  [ ! -e "$DESK/runs/sbx-12" ]
  [ -f "$DESK/archive/2026-10/sbx-12/plan.md" ]
  assert_output_not_contains "sbx-12 |"
  run grep -c 'sbx-12' "$DESK/index.md"
  [ "$output" = 0 ]
  run ns ls
  assert_output_not_contains "sbx-12"
  run ns ls --all
  assert_output_contains "sbx-12"
}

@test "a CLOSED PR removes local work but keeps the remote branches" {
  set_pr 102
  run ns gc
  assert_success
  assert_output_contains "remove worktree $WT"
  assert_output_contains "remove worktree $FWT"
  assert_output_contains "remove branch plan/sbx-12"
  assert_output_contains "remove tmux sbx-12"
  assert_output_contains "kept remote branches of sbx-12 (PR closed, not merged)"
  assert_output_not_contains "remove remote-branch"
  [ ! -e "$WT" ]
  [ ! -e "$FWT" ]
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
  [ -z "$(git -C "$PROJ" branch --list 'plan/sbx-12' 'feature/sbx-12' 'phase/sbx-12--p1')" ]
  [ -n "$(git ls-remote --heads "$REMOTE" 'plan/sbx-12')" ]
  [ -n "$(git ls-remote --heads "$REMOTE" 'phase/sbx-12--p1')" ]
  [ -n "$(git ls-remote --heads "$REMOTE" 'feature/sbx-12')" ]
  [ -f "$DESK/archive/2026-10/sbx-12/plan.md" ]
}

# make the run belong to another owner (acme) with its own PR number
set_owner_acme() {
  sed -i 's#andras-tkcs/nightshift-sandbox#acme/nightshift-sandbox#' "$NS_CONFIG_DIR/projects.yaml"
  grep -q 'acme/nightshift-sandbox' "$NS_CONFIG_DIR/projects.yaml"
  ns-ledger set "$LEDGER" ".pr=\"https://github.com/acme/nightshift-sandbox/pull/$1\""
  ns-ledger checkpoint "$LEDGER" --push
}

write_acme_token() {
  mkdir -p "$NS_CONFIG_DIR/tokens"
  printf 'github_pat_%s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAA >"$NS_CONFIG_DIR/tokens/acme"
  chmod "$1" "$NS_CONFIG_DIR/tokens/acme"
}

@test "a run of another owner uses that owner's token for gh and is cleaned" {
  set_owner_acme 104
  write_acme_token 600
  run ns gc
  assert_success
  assert_output_contains "remove worktree $WT"
  assert_output_contains "remove remote-branch origin/plan/sbx-12"
  [ ! -e "$WT" ]
  grep -q '^gh pr view https://github.com/acme/nightshift-sandbox/pull/104 --json state -q .state \[token\]$' "$GH_STUB_LOG"
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/out"
  refute_token_in "$GH_STUB_LOG" "$BATS_TEST_TMPDIR/out" "$NS_STUB_LOG"
}

@test "a run of another owner without a token file needs you and is kept" {
  # no token file: gh falls back to its default login, which cannot see acme (the stub has no answer for #105)
  set_owner_acme 105
  run ns gc
  assert_success
  assert_output_contains "needs you: sbx-12"
  assert_output_contains "1 item(s) need you"
  assert_output_not_contains "remove "
  [ -d "$WT" ]
  [ -d "$FWT" ]
  [ -d "$DESK/runs/sbx-12" ]
  [ -e "$TMUX_STUB_DIR/sbx-12" ]
}

@test "a token file with the wrong mode is reported and the run is kept" {
  set_owner_acme 104
  write_acme_token 644
  run ns gc
  assert_success
  assert_output_contains "needs you: sbx-12"
  assert_output_not_contains "remove "
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/out"
  refute_token_in "$BATS_TEST_TMPDIR/out"
  [ -d "$WT" ]
}

@test "a gh pr view failure is reported, not skipped silently" {
  set_pr 106
  run ns gc
  assert_success
  assert_output_contains "needs you: sbx-12: cannot read PR state"
  assert_output_contains "1 item(s) need you"
  assert_output_not_contains "remove "
  [ -d "$WT" ]
  [ -d "$FWT" ]
  [ -d "$DESK/runs/sbx-12" ]
}

@test "dry run lists the same items and changes nothing" {
  snapshot "$BATS_TEST_TMPDIR/before"
  run ns gc --dry-run
  assert_success
  assert_output_contains "would remove worktree $WT"
  assert_output_contains "would remove worktree $FWT"
  assert_output_contains "would remove branch plan/sbx-12"
  assert_output_contains "would remove remote-branch origin/plan/sbx-12"
  assert_output_contains "would remove tmux sbx-12"
  assert_output_contains "would remove desk $DESK/runs/sbx-12"
  assert_output_contains "ns gc (dry run): would free"
  assert_output_not_contains "ns gc: freed"
  snapshot "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  [ "$(lget .state)" = done ]
  run ns ls
  assert_output_contains "sbx-12"
}

@test "an OPEN PR keeps everything" {
  set_pr 103
  run ns gc
  assert_success
  assert_output_not_contains "remove "
  [ -d "$WT" ]
  [ -d "$DESK/runs/sbx-12" ]
}

@test "a run that is not done keeps everything" {
  ns-ledger set "$LEDGER" '.state="waiting"'
  ns-ledger checkpoint "$LEDGER" --push
  run ns gc
  assert_success
  assert_output_not_contains "remove "
  [ -d "$WT" ]
  [ -d "$FWT" ]
  [ -e "$TMUX_STUB_DIR/sbx-12" ]
}

@test "a dirty worktree needs you and is kept" {
  printf 'x\n' >"$FWT/scratch.txt"
  run ns gc
  assert_success
  assert_output_contains "needs you: $FWT: uncommitted changes"
  assert_output_contains "1 item(s) need you"
  assert_output_not_contains "remove worktree"
  [ -d "$WT" ]
  [ -d "$FWT" ]
  [ -d "$DESK/runs/sbx-12" ]
}

@test "a worktree with an unpushed commit needs you and is kept" {
  git -C "$FWT" commit -q --allow-empty -m "local only"
  run ns gc
  assert_success
  assert_output_contains "needs you: $FWT: unpushed commits"
  [ -d "$FWT" ]
  [ -d "$WT" ]
  [ -n "$(git -C "$PROJ" branch --list 'feature/sbx-12')" ]
}

@test "a worktree of another run with a similar id is not matched" {
  git -C "$PROJ" worktree add -q -b other "$WT"0 origin/main
  run ns gc
  assert_success
  [ -d "${WT}0" ]
  [ ! -e "$WT" ]
}

@test "desk archives older than 90 days are removed, younger kept" {
  mkdir -p "$DESK/archive/2026-06/old" "$DESK/archive/2026-07/young"
  printf 'x\n' >"$DESK/archive/2026-06/old/f"
  touch -d '91 days ago' "$DESK/archive/2026-06/old"
  touch -d '89 days ago' "$DESK/archive/2026-07/young"
  run ns gc --dry-run
  assert_output_contains "would remove archive $DESK/archive/2026-06/old"
  [ -d "$DESK/archive/2026-06/old" ]
  run ns gc
  assert_success
  assert_output_contains "remove archive $DESK/archive/2026-06/old"
  [ ! -e "$DESK/archive/2026-06/old" ]
  [ -d "$DESK/archive/2026-07/young" ]
}

@test "--monthly removes the pip cache" {
  mkdir -p "$HOME/.cache/pip"
  printf 'x\n' >"$HOME/.cache/pip/f"
  run ns gc
  assert_success
  [ -d "$HOME/.cache/pip" ]
  run ns gc --dry-run --monthly
  assert_output_contains "would remove cache $HOME/.cache/pip"
  [ -d "$HOME/.cache/pip" ]
  run ns gc --monthly
  assert_success
  assert_output_contains "remove cache $HOME/.cache/pip"
  [ ! -e "$HOME/.cache/pip" ]
}

@test "a reboot file adds reboot required to the summary" {
  : >"$BATS_TEST_TMPDIR/reboot"
  NS_REBOOT_FILE="$BATS_TEST_TMPDIR/reboot" run ns gc
  assert_success
  assert_output_contains "reboot required"
  run ns gc
  assert_output_not_contains "reboot required"
}

@test "the summary goes to ntfy when a topic is set" {
  NS_NTFY_TOPIC=topic run ns gc
  assert_success
  grep -q '^curl .*ns gc: freed' "$NS_STUB_LOG"
  : >"$NS_STUB_LOG"
  NS_NTFY_TOPIC=topic run ns gc --dry-run
  assert_success
  ! grep -q '^curl' "$NS_STUB_LOG"
}

@test "the healthcheck is pinged after success and not in a dry run" {
  NS_HEALTHCHECK_URL=https://hc.example/ping run ns gc --dry-run
  assert_success
  ! grep -q 'hc.example' "$NS_STUB_LOG"
  NS_HEALTHCHECK_URL=https://hc.example/ping run ns gc
  assert_success
  grep -q '^curl -fsS -m 10 https://hc.example/ping' "$NS_STUB_LOG"
}

@test "gc rejects unknown options" {
  run ns gc --bogus
  assert_failure 2
}

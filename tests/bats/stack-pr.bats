#!/usr/bin/env bats
# ns-73: stacked PRs, part 1 (ns-conductor stack-base, ns stack, stacked_on in ns status)

load helpers

setup() {
  ns_test_setup
  FIX="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIX/.claude"
  cp "$NS_REPO_ROOT/tests/fixtures/profiles/stack-pr.yaml" "$FIX/.claude/project-profile.yaml"
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  REMOTE="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T1 --yes >/dev/null
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  LEDGER="$WT/.nightshift/runs/sbx-12/ledger.yaml"
  export GH_STUB_RESPONSES="$BATS_TEST_TMPDIR/gh-responses"
  mkdir -p "$GH_STUB_RESPONSES"
  : >"$GH_STUB_RESPONSES/map"
  CODE_WT=$(ns-conductor fix-branch sbx-12)
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

# ns_project_path: the clone of the sandbox project
ns_project_path() { awk '$1 == "path:" {print $2; exit}' "$NS_CONFIG_DIR/projects.yaml"; }

# other_run_branch <branch> <base ref> <file> <content>: push a branch with one commit
other_run_branch() {
  local branch="$1" base="$2" file="$3" content="$4" w
  w="$(mktemp -d "$BATS_TEST_TMPDIR/other.XXXXXX")"
  git clone -q "$REMOTE" "$w"
  git -C "$w" checkout -q -b "$branch" "origin/$base"
  printf '%s\n' "$content" >"$w/$file"
  git -C "$w" add -A
  git -C "$w" commit -q -m "change $file on $branch"
  git -C "$w" push -q origin "$branch"
  rm -rf "$w"
}

# plan_branch <run id>: put plan/<run id> on origin (a PR only counts as a run PR then)
plan_branch() {
  local w
  w="$(mktemp -d "$BATS_TEST_TMPDIR/plan.XXXXXX")"
  git clone -q "$REMOTE" "$w"
  git -C "$w" push -q origin "HEAD:refs/heads/plan/$1"
  rm -rf "$w"
}

# pr_closed <json>: make `gh pr list --state closed` answer with the JSON.
# The stub takes the first matching map line, so pr_closed must stay ahead of the `^pr list` line.
pr_closed() {
  printf '%s\n' "$1" >"$GH_STUB_RESPONSES/pr-closed.json"
  { printf '0\tpr-closed.json\t^pr list .*--state closed\n'; cat "$GH_STUB_RESPONSES/map"; } >"$GH_STUB_RESPONSES/map.new"
  mv "$GH_STUB_RESPONSES/map.new" "$GH_STUB_RESPONSES/map"
}

# pr_list <json>: make `gh pr list` answer with the JSON
pr_list() {
  printf '%s\n' "$1" >"$GH_STUB_RESPONSES/pr-list.json"
  printf '0\tpr-list.json\t^pr list\n' >>"$GH_STUB_RESPONSES/map"
}

PRS_ONE='[
 {"number":5,"headRefName":"fix/sbx-11","baseRefName":"main","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":9,"headRefName":"dependabot/npm/x","baseRefName":"main","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"","statusCheckRollup":[]}
]'

PRS_TWO='[
 {"number":6,"headRefName":"fix/sbx-13","baseRefName":"fix/sbx-11","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":5,"headRefName":"fix/sbx-11","baseRefName":"main","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"APPROVED","statusCheckRollup":[]}
]'

@test "stack-base with no open run PR prints main and records stacked_on main" {
  pr_list '[]'
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$output" = main ]
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = main ]
}

@test "stack-base with one open run PR prints its branch, merges it and records its run id" {
  other_run_branch fix/sbx-11 main other.txt "from 11"
  plan_branch sbx-11
  pr_list "$PRS_ONE"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$output" = fix/sbx-11 ]
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = sbx-11 ]
  [ -f "$CODE_WT/other.txt" ]
  # a merge commit, never a rebase
  [ "$(git -C "$CODE_WT" rev-list --merges --count origin/main..HEAD)" -ge 1 ]
}

@test "stack-base picks the top of a two-PR stack" {
  other_run_branch fix/sbx-11 main other.txt "from 11"
  other_run_branch fix/sbx-13 fix/sbx-11 top.txt "top"
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$PRS_TWO"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$output" = fix/sbx-13 ]
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = sbx-13 ]
}

@test "stack-base exits 6 on a conflict, leaves the merge in progress and opens no PR" {
  printf 'mine\n' >"$CODE_WT/README.md"
  git -C "$CODE_WT" commit -q -am "mine"
  other_run_branch fix/sbx-11 main README.md "theirs"
  plan_branch sbx-11
  pr_list "$PRS_ONE"
  run ns-conductor stack-base sbx-12
  assert_failure 6
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = sbx-11 ]
  [ -f "$(git -C "$CODE_WT" rev-parse --absolute-git-dir)/MERGE_HEAD" ]
  run grep -q "pr create" "$GH_STUB_LOG"
  assert_failure 1
}

@test "ns stack lists the stack bottom to top" {
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$PRS_TWO"
  run ns stack sbx
  assert_success
  assert_output_contains "sbx-11"
  assert_output_contains "sbx-13"
  local l11 l13
  l11=$(grep -n "sbx-11" <<<"$output" | head -1 | cut -d: -f1)
  l13=$(grep -n "sbx-13" <<<"$output" | head -1 | cut -d: -f1)
  [ "$l11" -lt "$l13" ]
  assert_output_contains "#5"
  assert_output_contains "#6"
}

@test "ns stack --help succeeds" {
  run ns stack --help
  assert_success
  assert_output_contains "usage: ns stack"
}

@test "ns status shows stacked_on" {
  ns-ledger set "$LEDGER" '.stacked_on = "sbx-11"'
  run ns status sbx-12
  assert_success
  assert_output_contains "stacked  sbx-11"
}

@test "ns stack orders a chain deeper than 7 by depth, not by age" {
  local json="[" i base
  for i in 0 1 2 3 4 5 6 7 8 9; do
    if [ "$i" = 0 ]; then base=main; else base="fix/sbx-2$((i - 1))"; fi
    # deeper PRs are older, so a wrong depth would reorder them
    json+="{\"number\":$((30 + i)),\"headRefName\":\"fix/sbx-2$i\",\"baseRefName\":\"$base\",\"createdAt\":\"2026-10-02T1$((9 - i)):00:00Z\",\"reviewDecision\":\"\",\"statusCheckRollup\":[]}"
    [ "$i" = 9 ] || json+=","
  done
  json+="]"
  for i in 0 1 2 3 4 5 6 7 8 9; do plan_branch "sbx-2$i"; done
  pr_list "$json"
  run ns stack sbx
  assert_success
  local order
  order=$(awk '$1 ~ /^sbx-2/ {printf "%s ", $1}' <<<"$output")
  [ "$order" = "sbx-20 sbx-21 sbx-22 sbx-23 sbx-24 sbx-25 sbx-26 sbx-27 sbx-28 sbx-29 " ]
}

@test "a feature/<word> branch is not a run PR" {
  pr_list '[{"number":7,"headRefName":"feature/login","baseRefName":"main","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"","statusCheckRollup":[]}]'
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$output" = main ]
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = main ]
}

@test "a PR whose run has no plan branch on origin is not a run PR" {
  other_run_branch fix/sbx-11 main other.txt "from 11"
  pr_list "$PRS_ONE"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$output" = main ]
  [ ! -f "$CODE_WT/other.txt" ]
}

@test "ns stack ignores a PR without a plan branch on origin" {
  pr_list "$PRS_ONE"
  run ns stack sbx
  assert_success
  assert_output_contains "no open run PRs"
}

@test "stack-base records the profile's base branch, not main" {
  local clone
  clone=$(ns_project_path)
  # the profile is read from origin/main, so publish it there
  printf 'project: nightshift-sandbox\nprefix: sbx\ncommands:\n  setup: "true"\n  test: "true"\ngit:\n  base_branch: develop\nstacks: [python]\n' >"$clone/.claude/project-profile.yaml"
  git -C "$clone" add -A
  git -C "$clone" commit -q -m "base branch develop"
  git -C "$clone" push -q origin HEAD:main
  pr_list '[]'
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$output" = develop ]
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = develop ]
}

@test "stack-base names an untracked file the incoming branch adds" {
  other_run_branch fix/sbx-11 main other.txt "from 11"
  plan_branch sbx-11
  pr_list "$PRS_ONE"
  printf 'mine\n' >"$CODE_WT/other.txt"
  run ns-conductor stack-base sbx-12
  assert_failure
  assert_output_contains "other.txt"
  assert_output_contains "untracked"
  case "$output" in *Aborting*) echo "the merge ran: $output" >&2; return 1 ;; esac
  [ "$(cat "$CODE_WT/other.txt")" = mine ]
}

PRS_CHAINS='[
 {"number":5,"headRefName":"fix/sbx-11","baseRefName":"main","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":6,"headRefName":"fix/sbx-13","baseRefName":"main","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"","statusCheckRollup":[]}
]'

@test "stack-base exits 7 naming the tops when there is more than one chain" {
  other_run_branch fix/sbx-11 main a.txt "a"
  other_run_branch fix/sbx-13 main b.txt "b"
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$PRS_CHAINS"
  run ns-conductor stack-base sbx-12
  assert_failure 7
  assert_output_contains "fix/sbx-11"
  assert_output_contains "fix/sbx-13"
  [ ! -f "$CODE_WT/a.txt" ]
  [ ! -f "$CODE_WT/b.txt" ]
}

@test "ns stack prints each chain separately" {
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$PRS_CHAINS"
  run ns stack sbx
  assert_success
  assert_output_contains "chain 1"
  assert_output_contains "chain 2"
}

PRS_ABOVE_CLOSED='[
 {"number":6,"headRefName":"fix/sbx-13","baseRefName":"fix/sbx-11","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"","statusCheckRollup":[]}
]'
CLOSED_11='[{"number":5,"headRefName":"fix/sbx-11","state":"CLOSED","mergedAt":null}]'

@test "ns stack marks a PR whose base PR was closed unmerged" {
  plan_branch sbx-13
  pr_list "$PRS_ABOVE_CLOSED"
  pr_closed "$CLOSED_11"
  run ns stack sbx
  assert_success
  assert_output_contains "base closed"
}

@test "stack-base warns about a closed lower PR and points to ns stack drop" {
  other_run_branch fix/sbx-13 main top.txt "top"
  plan_branch sbx-13
  pr_list "$PRS_ABOVE_CLOSED"
  pr_closed "$CLOSED_11"
  run ns-conductor stack-base sbx-12
  assert_success
  assert_output_contains "sbx-13"
  assert_output_contains "closed"
  assert_output_contains "ns stack drop"
}

@test "stack-base warns when its own stacked_on run PR was closed unmerged" {
  ns-ledger set "$LEDGER" '.stacked_on = "sbx-11"'
  pr_list '[]'
  pr_closed "$CLOSED_11"
  run ns-conductor stack-base sbx-12
  assert_success
  assert_output_contains "sbx-12"
  assert_output_contains "ns stack drop"
}

@test "stack-base fails when the origin cannot be listed" {
  other_run_branch fix/sbx-11 main one.txt "one"
  plan_branch sbx-11
  pr_list "$PRS_ONE"
  git -C "$(ns_project_path)" remote set-url origin "$BATS_TEST_TMPDIR/no-such-remote.git"
  run ns-conductor stack-base sbx-12
  assert_failure
  assert_output_contains "could not list"
}

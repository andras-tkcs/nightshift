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

# pr_list <json>: make `gh pr list` answer with the JSON
pr_list() {
  printf '%s\n' "$1" >"$GH_STUB_RESPONSES/pr-list.json"
  printf '0\tpr-list.json\t^pr list\n' >"$GH_STUB_RESPONSES/map"
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
  pr_list "$PRS_ONE"
  run ns-conductor stack-base sbx-12
  assert_failure 6
  [ -f "$(git -C "$CODE_WT" rev-parse --absolute-git-dir)/MERGE_HEAD" ]
  run grep -q "pr create" "$GH_STUB_LOG"
  assert_failure 1
}

@test "ns stack lists the stack bottom to top" {
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
  pr_list "$json"
  run ns stack sbx
  assert_success
  local order
  order=$(grep -o 'sbx-2[0-9]' <<<"$output" | tr '\n' ' ')
  [ "$order" = "sbx-20 sbx-21 sbx-22 sbx-23 sbx-24 sbx-25 sbx-26 sbx-27 sbx-28 sbx-29 " ]
}

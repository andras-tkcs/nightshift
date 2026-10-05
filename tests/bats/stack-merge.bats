#!/usr/bin/env bats
# ns-74: stacked PRs, part 2 (ns stack merge, ns stack drop)

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
  export GH_STUB_RESPONSES="$BATS_TEST_TMPDIR/gh-responses"
  mkdir -p "$GH_STUB_RESPONSES"
  : >"$GH_STUB_RESPONSES/map"
  # pr edit / merge / close and pr view all succeed; the list answers come from pr_list
  printf '0\t-\t^pr (edit|merge|close) \n' >>"$GH_STUB_RESPONSES/map"
  printf '{"mergeable":"MERGEABLE","state":"OPEN"}\n' >"$GH_STUB_RESPONSES/pr-view.json"
  printf '0\tpr-view.json\t^pr view\n' >>"$GH_STUB_RESPONSES/map"
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

# run_branch <branch> <base ref> <file> <content>: push a branch with one commit
run_branch() {
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

plan_branch() {
  local w
  w="$(mktemp -d "$BATS_TEST_TMPDIR/plan.XXXXXX")"
  git clone -q "$REMOTE" "$w"
  git -C "$w" push -q origin "HEAD:refs/heads/plan/$1"
  rm -rf "$w"
}

# pr_list <json>: make `gh pr list` answer with the JSON (ahead of the generic lines)
pr_list() {
  printf '%s\n' "$1" >"$GH_STUB_RESPONSES/pr-list.json"
  { printf '0\tpr-list.json\t^pr list\n'; cat "$GH_STUB_RESPONSES/map"; } >"$GH_STUB_RESPONSES/map.new"
  mv "$GH_STUB_RESPONSES/map.new" "$GH_STUB_RESPONSES/map"
}

# stack3 <review of the middle PR>: sbx-11 (#5) <- sbx-13 (#6) <- sbx-14 (#7) on main
stack3() {
  local mid="$1"
  run_branch fix/sbx-11 main a.txt a
  run_branch fix/sbx-13 fix/sbx-11 b.txt b
  run_branch fix/sbx-14 fix/sbx-13 c.txt c
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  pr_list '[
 {"number":5,"headRefName":"fix/sbx-11","baseRefName":"main","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[]},
 {"number":6,"headRefName":"fix/sbx-13","baseRefName":"fix/sbx-11","createdAt":"2026-10-02T11:00:00Z","reviewDecision":"'"$mid"'","mergeable":"MERGEABLE","statusCheckRollup":[]},
 {"number":7,"headRefName":"fix/sbx-14","baseRefName":"fix/sbx-13","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[]}
]'
}

# line_of <pattern>: line number of the first gh log line matching the pattern
line_of() { grep -n -- "$1" "$GH_STUB_LOG" | head -1 | cut -d: -f1 || true; }

@test "ns stack merge lands three approved PRs bottom to top, retargeting each next base first" {
  stack3 APPROVED
  run ns stack merge sbx
  assert_success
  local m5 m6 m7 e6 e7
  m5=$(line_of "pr merge 5 ")
  m6=$(line_of "pr merge 6 ")
  m7=$(line_of "pr merge 7 ")
  e6=$(line_of "pr edit 6 .*--base main")
  e7=$(line_of "pr edit 7 .*--base main")
  [ -n "$m5" ] && [ -n "$m6" ] && [ -n "$m7" ] && [ -n "$e6" ] && [ -n "$e7" ]
  # the next PR is retargeted to main before the PR below it is merged
  [ "$e6" -lt "$m5" ]
  [ "$e7" -lt "$m6" ]
  [ "$m5" -lt "$m6" ]
  [ "$m6" -lt "$m7" ]
}

@test "ns stack merge stops at an unapproved middle PR, merging only the bottom and saying why" {
  stack3 REVIEW_REQUIRED
  run ns stack merge sbx
  assert_failure
  assert_output_contains "#6"
  assert_output_contains "not approved"
  assert_output_contains "left"
  [ -n "$(line_of "pr merge 5 ")" ]
  [ -z "$(line_of "pr merge 6 ")" ]
  [ -z "$(line_of "pr merge 7 ")" ]
}

@test "ns stack merge --dry-run prints the plan and changes nothing" {
  stack3 APPROVED
  run ns stack merge sbx --dry-run
  assert_success
  assert_output_contains "#5"
  assert_output_contains "#6"
  assert_output_contains "#7"
  run grep -E "^gh pr (merge|edit|close)" "$GH_STUB_LOG"
  assert_failure 1
}

@test "ns stack drop closes the middle PR and restacks the top onto the bottom" {
  stack3 APPROVED
  # the bottom moves on after the layers above were built, so the top needs a real merge
  local w
  w="$(mktemp -d "$BATS_TEST_TMPDIR/bottom.XXXXXX")"
  git clone -q "$REMOTE" "$w"
  git -C "$w" checkout -q -b fix/sbx-11 origin/fix/sbx-11
  printf 'later\n' >"$w/later.txt"
  git -C "$w" add -A
  git -C "$w" commit -q -m "bottom moves on"
  git -C "$w" push -q origin fix/sbx-11
  rm -rf "$w"
  run ns stack drop sbx-13
  assert_success
  [ -n "$(line_of "pr close 6")" ]
  [ -n "$(line_of "pr edit 7 .*--base fix/sbx-11")" ]
  git -C "$REMOTE" merge-base --is-ancestor fix/sbx-11 fix/sbx-14
}

@test "ns stack drop --dry-run prints the plan and changes nothing" {
  stack3 APPROVED
  local before
  before=$(git -C "$REMOTE" rev-parse fix/sbx-14)
  run ns stack drop sbx-13 --dry-run
  assert_success
  assert_output_contains "#6"
  run grep -E "^gh pr (merge|edit|close)" "$GH_STUB_LOG"
  assert_failure 1
  [ "$(git -C "$REMOTE" rev-parse fix/sbx-14)" = "$before" ]
}

# set_lint <cmd>: change the lint check of the profile on the default branch of the remote
set_lint() {
  local w tree commit
  w="$(mktemp -d "$BATS_TEST_TMPDIR/prof.XXXXXX")"
  git clone -q "$REMOTE" "$w"
  sed -i "s|^  lint: .*|  lint: \"$1\"|" "$w/.claude/project-profile.yaml"
  git -C "$w" commit -q -am "profile lint $1"
  commit=$(git -C "$w" rev-parse HEAD)
  git -C "$REMOTE" fetch -q "$w" HEAD
  git -C "$REMOTE" update-ref HEAD "$commit"
  rm -rf "$w"
}

@test "ns stack merge runs the profile checks on the top of the stack, then merges" {
  stack3 APPROVED
  run ns stack merge sbx
  assert_success
  assert_output_contains "check python lint: pass"
  [ -n "$(line_of "pr merge 7 ")" ]
}

@test "ns stack merge merges nothing when the profile checks fail on the top of the stack" {
  stack3 APPROVED
  set_lint false
  run ns stack merge sbx
  assert_failure
  assert_output_contains "checks failed on top of the stack (#7)"
  [ -z "$(line_of "pr merge")" ]
}

@test "ns stack merge --dry-run lists the checks step" {
  stack3 APPROVED
  run ns stack merge sbx --dry-run
  assert_success
  assert_output_contains "profile checks on the top of the stack (#7)"
}

@test "ns stack merge stops at a middle PR with failing checks" {
  stack3 APPROVED
  pr_list '[
 {"number":5,"headRefName":"fix/sbx-11","baseRefName":"main","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[]},
 {"number":6,"headRefName":"fix/sbx-13","baseRefName":"fix/sbx-11","createdAt":"2026-10-02T11:00:00Z","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED"}]},
 {"number":7,"headRefName":"fix/sbx-14","baseRefName":"fix/sbx-13","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[]}
]'
  run ns stack merge sbx
  assert_failure
  assert_output_contains "#6"
  assert_output_contains "not green"
  [ -n "$(line_of "pr merge 5 ")" ]
  [ -z "$(line_of "pr merge 6 ")" ]
  [ -z "$(line_of "pr merge 7 ")" ]
}

@test "ns stack merge stops at a PR that has new conflicts" {
  stack3 APPROVED
  { printf '0\tpr-view6.json\t^pr view 6 \n'; cat "$GH_STUB_RESPONSES/map"; } >"$GH_STUB_RESPONSES/map.new"
  mv "$GH_STUB_RESPONSES/map.new" "$GH_STUB_RESPONSES/map"
  printf '{"mergeable":"CONFLICTING","state":"OPEN"}\n' >"$GH_STUB_RESPONSES/pr-view6.json"
  run ns stack merge sbx
  assert_failure
  assert_output_contains "#6"
  assert_output_contains "conflicts"
  [ -n "$(line_of "pr merge 5 ")" ]
  [ -z "$(line_of "pr merge 6 ")" ]
  [ -z "$(line_of "pr merge 7 ")" ]
}

@test "ns stack drop reverts the dropped change in the PR above" {
  stack3 APPROVED
  run ns stack drop sbx-13
  assert_success
  assert_output_contains "reverted"
  local w
  w="$(mktemp -d "$BATS_TEST_TMPDIR/chk.XXXXXX")"
  git clone -q "$REMOTE" "$w"
  git -C "$w" checkout -q fix/sbx-14
  [ ! -e "$w/b.txt" ]
  [ -e "$w/c.txt" ]
  [ -e "$w/a.txt" ]
}

@test "ns stack drop stops and names the PR above when the revert does not apply" {
  stack3 APPROVED
  # the top layer edits the file the dropped layer added, so its change cannot be taken out
  local w before
  w="$(mktemp -d "$BATS_TEST_TMPDIR/top.XXXXXX")"
  git clone -q "$REMOTE" "$w"
  git -C "$w" checkout -q -b fix/sbx-14 origin/fix/sbx-14
  printf 'edited above\n' >"$w/b.txt"
  git -C "$w" commit -q -am "top edits b.txt"
  git -C "$w" push -q origin fix/sbx-14
  rm -rf "$w"
  before=$(git -C "$REMOTE" rev-parse fix/sbx-14)
  run ns stack drop sbx-13
  assert_failure
  assert_output_contains "#7"
  [ -z "$(line_of "pr close 6")" ]
  [ -z "$(line_of "pr edit 7")" ]
  [ "$(git -C "$REMOTE" rev-parse fix/sbx-14)" = "$before" ]
}

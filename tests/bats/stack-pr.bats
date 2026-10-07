#!/usr/bin/env bats
# ns-73: stacked PRs, part 1 (ns-conductor stack-base, ns stack, stacked_on in ns status)

load helpers
load stack-gh

fixture_vars() {
  FIX="$BATS_TEST_TMPDIR/fixture"
  REMOTE="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  LEDGER="$WT/.nightshift/runs/sbx-12/ledger.yaml"
}

# the slow part of the setup, run once per file (ns_cached_fixture)
fixture_build() {
  fixture_vars
  mkdir -p "$FIX/.claude"
  cp "$NS_REPO_ROOT/tests/fixtures/profiles/stack-pr.yaml" "$FIX/.claude/project-profile.yaml"
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T1 --yes >/dev/null
}

setup() {
  ns_test_setup
  ns_cached_fixture fixture_build
  fixture_vars
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

# pr_closed <json>: make the closed-PR search answer with the JSON (flat `gh pr list` shape)
pr_closed() { stub_closed_prs "$1"; }

# pr_list <json>: make the open-PR query answer with the JSON (flat `gh pr list` shape)
pr_list() { stub_open_prs "$1" append; }

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
CLOSED_11='[{"number":5,"headRefName":"fix/sbx-11","baseRefName":"main","state":"CLOSED","mergedAt":null}]'

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

# ns-97: a reused branch name is not a closed base; a fork is several chains
CLOSED_11_OLD='[{"number":4,"headRefName":"fix/sbx-11","state":"CLOSED","mergedAt":null,"closedAt":"2026-10-01T09:00:00Z"}]'

@test "ns stack: a closed PR that predates the dependent PR is not a closed base" {
  plan_branch sbx-13
  pr_list "$PRS_ABOVE_CLOSED"
  pr_closed "$CLOSED_11_OLD"
  run ns stack sbx
  assert_success
  case "$output" in *"base closed"*) echo "false base closed: $output" >&2; return 1 ;; esac
  # no PR of fix/sbx-11 was found for #6, so its base branch is unknown
  assert_output_contains "base unknown"
}

@test "ns stack: an open PR with the same head hides the closed one" {
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$PRS_TWO"
  pr_closed "$CLOSED_11"
  run ns stack sbx
  assert_success
  case "$output" in *"base closed"*) echo "false base closed: $output" >&2; return 1 ;; esac
}

@test "stack-base: a closed PR that predates the dependent PR gives no closed warning; the base is unknown: gate 1.5" {
  other_run_branch fix/sbx-13 main top.txt "top"
  plan_branch sbx-13
  pr_list "$PRS_ABOVE_CLOSED"
  pr_closed "$CLOSED_11_OLD"
  run ns-conductor stack-base sbx-12
  case "$output" in *"ns stack drop"*) echo "false warning: $output" >&2; return 1 ;; esac
  # review S2: a chain whose base PR is not found may belong to another base branch: escalate
  assert_failure 7
  assert_output_contains "#6"
  assert_output_contains "fix/sbx-11"
  [ ! -f "$CODE_WT/top.txt" ]
}

@test "stack-base: an open PR with the same head gives no closed warning" {
  other_run_branch fix/sbx-11 main other.txt "from 11"
  other_run_branch fix/sbx-13 fix/sbx-11 top.txt "top"
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$PRS_TWO"
  pr_closed "$CLOSED_11"
  run ns-conductor stack-base sbx-12
  assert_success
  case "$output" in *"ns stack drop"*) echo "false warning: $output" >&2; return 1 ;; esac
}

PRS_TWO_DEPS='[
 {"number":5,"headRefName":"fix/sbx-11","baseRefName":"main","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":6,"headRefName":"fix/sbx-13","baseRefName":"fix/sbx-11","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":8,"headRefName":"fix/sbx-14","baseRefName":"fix/sbx-15","createdAt":"2026-10-02T12:30:00Z","reviewDecision":"","statusCheckRollup":[]}
]'
CLOSED_REUSED_AND_TRUE='[
 {"number":4,"headRefName":"fix/sbx-11","baseRefName":"main","state":"CLOSED","mergedAt":null,"closedAt":"2026-10-02T13:00:00Z"},
 {"number":7,"headRefName":"fix/sbx-15","baseRefName":"main","state":"CLOSED","mergedAt":null,"closedAt":"2026-10-02T13:00:00Z"}
]'

@test "ns stack: with two dependents only the one on a truly closed base is marked" {
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  pr_list "$PRS_TWO_DEPS"
  pr_closed "$CLOSED_REUSED_AND_TRUE"
  run ns stack sbx
  assert_success
  [ "$(grep -c "base closed" <<<"$output")" -eq 1 ]
  grep "base closed" <<<"$output" | grep -q "sbx-14"
}

@test "stack-base: with two dependents only the truly closed base is warned about" {
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  pr_list "$PRS_TWO_DEPS"
  pr_closed "$CLOSED_REUSED_AND_TRUE"
  run ns-conductor stack-base sbx-12
  assert_output_contains "fix/sbx-15"
  case "$output" in *"(fix/sbx-11)"*) echo "false warning: $output" >&2; return 1 ;; esac
}

@test "stack-base: an old closed PR with the own stacked_on head gives no warning" {
  ns-ledger set "$LEDGER" '.stacked_on = "sbx-11"'
  pr_list '[]'
  pr_closed '[{"number":4,"headRefName":"fix/sbx-11","state":"CLOSED","mergedAt":null,"closedAt":"2020-01-01T00:00:00Z"}]'
  run ns-conductor stack-base sbx-12
  assert_success
  case "$output" in *"ns stack drop"*) echo "false warning: $output" >&2; return 1 ;; esac
}

PRS_CYCLE='[
 {"number":5,"headRefName":"fix/sbx-11","baseRefName":"fix/sbx-13","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":6,"headRefName":"fix/sbx-13","baseRefName":"fix/sbx-11","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"","statusCheckRollup":[]}
]'

@test "ns stack: PRs whose bases form a cycle are still listed" {
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$PRS_CYCLE"
  run ns stack sbx
  assert_success
  assert_output_contains "#5"
  assert_output_contains "#6"
}

PRS_FORK='[
 {"number":5,"headRefName":"fix/sbx-11","baseRefName":"main","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":6,"headRefName":"fix/sbx-13","baseRefName":"fix/sbx-11","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":7,"headRefName":"fix/sbx-14","baseRefName":"fix/sbx-11","createdAt":"2026-10-02T13:00:00Z","reviewDecision":"","statusCheckRollup":[]}
]'

@test "ns stack prints a fork as two chains" {
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  pr_list "$PRS_FORK"
  run ns stack sbx
  assert_success
  assert_output_contains "chain 1"
  assert_output_contains "chain 2"
}

@test "stack-base exits 7 naming both tops of a fork" {
  other_run_branch fix/sbx-11 main a.txt "a"
  other_run_branch fix/sbx-13 fix/sbx-11 b.txt "b"
  other_run_branch fix/sbx-14 fix/sbx-11 c.txt "c"
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  pr_list "$PRS_FORK"
  run ns-conductor stack-base sbx-12
  assert_failure 7
  assert_output_contains "fix/sbx-13"
  assert_output_contains "fix/sbx-14"
}

# sprint (#122): a stack belongs to one base branch; run PRs whose chain targets another base do not count
PRS_OTHER_BASES='[
 {"number":1,"headRefName":"fix/sbx-11","baseRefName":"e2e/20261002-1","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":3,"headRefName":"fix/sbx-13","baseRefName":"e2e/20261002-2","createdAt":"2026-10-02T11:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":4,"headRefName":"fix/sbx-14","baseRefName":"fix/sbx-13","createdAt":"2026-10-02T11:30:00Z","reviewDecision":"","statusCheckRollup":[]}
]'

@test "stack-base ignores open run PRs whose chain targets another base branch" {
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  pr_list "$PRS_OTHER_BASES"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$output" = main ]
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = main ]
}

@test "stack-base stacks on the chain of its own base branch next to chains on other bases" {
  other_run_branch fix/sbx-15 main other.txt "from 15"
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  plan_branch sbx-15
  pr_list "$(jq -c '. + [{"number":8,"headRefName":"fix/sbx-15","baseRefName":"main","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"","statusCheckRollup":[]}]' <<<"$PRS_OTHER_BASES")"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$output" = fix/sbx-15 ]
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = sbx-15 ]
}

@test "ns stack lists only the chains of the base branch and counts the others" {
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  plan_branch sbx-15
  pr_list "$(jq -c '. + [{"number":8,"headRefName":"fix/sbx-15","baseRefName":"main","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"","statusCheckRollup":[]}]' <<<"$PRS_OTHER_BASES")"
  run ns stack sbx
  assert_success
  assert_output_contains "#8"
  case "$output" in *"chain 2"* | *" #1 "* | *" #4 "*) echo "other base listed: $output" >&2; return 1 ;; esac
  assert_output_contains "3 open run PRs target other base branches"
}

# set_base_branch <branch>: publish a profile with that base branch on origin/main
set_base_branch() {
  local clone
  clone=$(ns_project_path)
  printf 'project: nightshift-sandbox\nprefix: sbx\ncommands:\n  setup: "true"\n  test: "true"\ngit:\n  base_branch: %s\nstacks: [python]\n' "$1" >"$clone/.claude/project-profile.yaml"
  git -C "$clone" add -A
  git -C "$clone" commit -q -m "base branch $1"
  git -C "$clone" push -q origin HEAD:main
}

@test "stack-base exit 7 names the profile's base branch as a choice, not main" {
  set_base_branch develop
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list '[
 {"number":5,"headRefName":"fix/sbx-11","baseRefName":"develop","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":6,"headRefName":"fix/sbx-13","baseRefName":"develop","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"","statusCheckRollup":[]}
]'
  run ns-conductor stack-base sbx-12
  assert_failure 7
  assert_output_contains "develop, fix/sbx-11 or fix/sbx-13"
  case "$output" in *main*) echo "names main: $output" >&2; return 1 ;; esac
}

# #85 item 1: more than 100 open PRs; the run PR is on the second page
prs_150() {
  jq -nc '[range(1; 150) | {number: ., headRefName: "dependabot/npm/x\(.)", baseRefName: "main", createdAt: "2026-10-01T10:00:00Z", reviewDecision: "", statusCheckRollup: []}]
    + [{number: 150, headRefName: "fix/sbx-11", baseRefName: "main", createdAt: "2026-10-02T10:00:00Z", reviewDecision: "", statusCheckRollup: []}]'
}

@test "stack-base finds a run PR past the first 100 open PRs" {
  other_run_branch fix/sbx-11 main other.txt "from 11"
  plan_branch sbx-11
  pr_list "$(prs_150)"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$output" = fix/sbx-11 ]
  grep -q "api graphql --paginate" "$GH_STUB_LOG"
}

@test "ns stack marks a closed base found past the first 100 closed PRs" {
  plan_branch sbx-13
  pr_list "$PRS_ABOVE_CLOSED"
  pr_closed "$(jq -nc '[range(1; 150) | {number: (1000 + .), headRefName: "old/x\(.)", state: "CLOSED", mergedAt: null, closedAt: "2026-10-02T13:00:00Z"}]
    + [{number: 5, headRefName: "fix/sbx-11", baseRefName: "main", state: "CLOSED", mergedAt: null, closedAt: "2026-10-02T13:00:00Z"}]')"
  run ns stack sbx
  assert_success
  assert_output_contains "base closed"
}

# #119 item 6: no closed list when no base can be a closed PR and the run is not stacked on another run
@test "stack-base does not fetch the closed PRs when every base is the base branch or an open PR" {
  other_run_branch fix/sbx-11 main other.txt "from 11"
  other_run_branch fix/sbx-13 fix/sbx-11 top.txt "top"
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$PRS_TWO"
  pr_closed "$CLOSED_11"
  run ns-conductor stack-base sbx-12
  assert_success
  run grep -E "ClosedRunPRs|--state closed" "$GH_STUB_LOG"
  assert_failure 1
}

# #119 item 7: this run's own open PR hides a closed PR with the same head (a reused name)
@test "stack-base: a closed PR with the head of this run's own open PR gives no closed warning" {
  other_run_branch fix/sbx-13 main top.txt "top"
  git ls-remote --exit-code "$REMOTE" refs/heads/plan/sbx-12 >/dev/null || plan_branch sbx-12
  plan_branch sbx-13
  pr_list '[
 {"number":7,"headRefName":"fix/sbx-12","baseRefName":"main","createdAt":"2026-10-02T09:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":8,"headRefName":"fix/sbx-13","baseRefName":"fix/sbx-12","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"","statusCheckRollup":[]}
]'
  pr_closed '[{"number":4,"headRefName":"fix/sbx-12","baseRefName":"main","state":"CLOSED","mergedAt":null,"closedAt":"2026-10-02T13:00:00Z"}]'
  run ns-conductor stack-base sbx-12
  case "$output" in *"closed without a merge"*) echo "false warning: $output" >&2; return 1 ;; esac
  assert_success
  [ "$(tail -n 1 <<<"$output")" = fix/sbx-13 ]
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = sbx-13 ]
}

# #119 item 5: a cycle next to a normal chain, and a leaf above a cycle
PRS_PARTIAL_CYCLE='[
 {"number":5,"headRefName":"fix/sbx-11","baseRefName":"main","createdAt":"2026-10-02T10:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":6,"headRefName":"fix/sbx-13","baseRefName":"fix/sbx-14","createdAt":"2026-10-02T11:00:00Z","reviewDecision":"","statusCheckRollup":[]},
 {"number":7,"headRefName":"fix/sbx-14","baseRefName":"fix/sbx-13","createdAt":"2026-10-02T12:00:00Z","reviewDecision":"","statusCheckRollup":[]}
]'

@test "ns stack warns about a partial cycle and still lists the PRs in it" {
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  pr_list "$PRS_PARTIAL_CYCLE"
  run ns stack sbx
  assert_success
  assert_output_contains "cycle"
  assert_output_contains "#5"
  assert_output_contains "#6"
  assert_output_contains "#7"
}

@test "ns stack lists a leaf above a cycle once per PR, with a warning" {
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  plan_branch sbx-15
  pr_list "$(jq -c '. + [{"number":8,"headRefName":"fix/sbx-15","baseRefName":"fix/sbx-13","createdAt":"2026-10-02T13:00:00Z","reviewDecision":"","statusCheckRollup":[]}]' <<<"$PRS_PARTIAL_CYCLE")"
  run ns stack sbx
  assert_success
  assert_output_contains "cycle"
  [ "$(grep -cE '^  sbx-[0-9]+ +#6 ' <<<"$output")" -eq 1 ]
  [ "$(grep -cE '^  sbx-[0-9]+ +#7 ' <<<"$output")" -eq 1 ]
  [ "$(grep -cE '^  sbx-[0-9]+ +#8 ' <<<"$output")" -eq 1 ]
}

# #85 item 2 (owner's decision): stack on the nearest PR below a red one, and say so
FAIL_ROLLUP='[{"__typename":"CheckRun","name":"tests","conclusion":"FAILURE","status":"COMPLETED"}]'
PEND_ROLLUP='[{"__typename":"CheckRun","name":"tests","conclusion":null,"status":"IN_PROGRESS"}]'

# prs_two_top <rollup of the top PR> [rollup of the bottom PR]: PRS_TWO with those check states
prs_two_top() {
  jq -c --argjson t "$1" --argjson b "${2:-[]}" 'map(if .number == 6 then .statusCheckRollup = $t else .statusCheckRollup = $b end)' <<<"$PRS_TWO"
}

@test "stack-base skips a top PR with failing checks and stacks on the PR below" {
  other_run_branch fix/sbx-11 main other.txt "from 11"
  other_run_branch fix/sbx-13 fix/sbx-11 top.txt "top"
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$(prs_two_top "$FAIL_ROLLUP")"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$(tail -n 1 <<<"$output")" = fix/sbx-11 ]
  assert_output_contains "Stacked on #5 (checks failing on #6)"
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = sbx-11 ]
  [ "$(ns-ledger get "$LEDGER" '.stack_skipped | map(.number) | join(",")')" = 6 ]
  ns-ledger get "$LEDGER" '.events[] | select(.type == "stack") | .note' | grep -qF "Stacked on #5 (checks failing on #6)"
  [ -f "$CODE_WT/other.txt" ]
  [ ! -f "$CODE_WT/top.txt" ]
}

@test "stack-base stacks on the base branch when every PR of the chain is red" {
  other_run_branch fix/sbx-11 main other.txt "from 11"
  other_run_branch fix/sbx-13 fix/sbx-11 top.txt "top"
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$(prs_two_top "$FAIL_ROLLUP" "$FAIL_ROLLUP")"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$(tail -n 1 <<<"$output")" = main ]
  assert_output_contains "Stacked on main (checks failing on #6, #5)"
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = main ]
  [ "$(ns-ledger get "$LEDGER" '.stack_skipped | map(.number) | join(",")')" = "6,5" ]
  [ ! -f "$CODE_WT/other.txt" ]
}

@test "stack-base stacks on a top PR whose checks are pending (pending is not red)" {
  other_run_branch fix/sbx-11 main other.txt "from 11"
  other_run_branch fix/sbx-13 fix/sbx-11 top.txt "top"
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$(prs_two_top "$PEND_ROLLUP")"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$output" = fix/sbx-13 ]
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = sbx-13 ]
  [ "$(ns-ledger get "$LEDGER" '.stack_skipped // [] | length')" = 0 ]
}

# review B1: red leaves are pruned before the chains are counted, so a red skip never forces gate 1.5
# prs <num:head:base:g|r|p>...: open run PRs with green, red or pending checks (createdAt by number)
prs() {
  local t json="[]" n h b c roll
  for t in "$@"; do
    IFS=: read -r n h b c <<<"$t"
    case "$c" in r) roll="$FAIL_ROLLUP" ;; p) roll="$PEND_ROLLUP" ;; *) roll='[{"__typename":"CheckRun","name":"tests","conclusion":"SUCCESS","status":"COMPLETED"}]' ;; esac
    json=$(jq -c --argjson n "$n" --arg h "$h" --arg b "$b" --argjson r "$roll" \
      '. + [{number: $n, headRefName: $h, baseRefName: $b, createdAt: ("2026-10-02T1\($n % 10):00:00Z"), reviewDecision: "", statusCheckRollup: $r}]' <<<"$json")
  done
  printf '%s\n' "$json"
}

# skipped: the ledger's stack_skipped numbers, sorted
skipped() { ns-ledger get "$LEDGER" '(.stack_skipped // []) | map(.number) | sort | map(tostring) | join(",")'; }

@test "stack-base: a red leaf beside a green leaf is pruned and the run stacks on the green one (B1 a)" {
  other_run_branch fix/sbx-11 main a.txt a
  other_run_branch fix/sbx-14 fix/sbx-11 c.txt c
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  pr_list "$(prs 5:fix/sbx-11:main:g 6:fix/sbx-13:fix/sbx-11:r 7:fix/sbx-14:fix/sbx-11:g)"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$(tail -n 1 <<<"$output")" = fix/sbx-14 ]
  assert_output_contains "Stacked on #7 (checks failing on #6)"
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = sbx-14 ]
  [ "$(skipped)" = 6 ]
}

@test "stack-base: two green leaves left after pruning: exit 7 offers only the base and the green tops (B1 b)" {
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  plan_branch sbx-15
  pr_list "$(prs 5:fix/sbx-11:main:g 6:fix/sbx-13:fix/sbx-11:r 7:fix/sbx-14:fix/sbx-11:g 8:fix/sbx-15:fix/sbx-11:g)"
  run ns-conductor stack-base sbx-12
  assert_failure 7
  assert_output_contains "main, fix/sbx-14 or fix/sbx-15"
  case "$(grep "choose a base" <<<"$output")" in *fix/sbx-13*) echo "offers the red PR: $output" >&2; return 1 ;; esac
  [ "$(skipped)" = 6 ]
}

@test "stack-base: two chains from the base branch, one all red: stacks on the green top (B1 c)" {
  other_run_branch fix/sbx-11 main a.txt a
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$(prs 5:fix/sbx-11:main:g 6:fix/sbx-13:main:r)"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$(tail -n 1 <<<"$output")" = fix/sbx-11 ]
  [ "$(skipped)" = 6 ]
}

@test "stack-base: a red PR with a green PR above it is kept; its red sibling leaf is pruned (B1 d)" {
  other_run_branch fix/sbx-11 main a.txt a
  other_run_branch fix/sbx-14 fix/sbx-11 c.txt c
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  pr_list "$(prs 5:fix/sbx-11:main:r 6:fix/sbx-13:fix/sbx-11:r 7:fix/sbx-14:fix/sbx-11:g)"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$(tail -n 1 <<<"$output")" = fix/sbx-14 ]
  [ "$(skipped)" = 6 ]
}

@test "stack-base: only tops decide: a red middle PR under a green top prunes nothing (B1 e)" {
  other_run_branch fix/sbx-11 main a.txt a
  other_run_branch fix/sbx-13 fix/sbx-11 b.txt b
  other_run_branch fix/sbx-14 fix/sbx-13 c.txt c
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  pr_list "$(prs 5:fix/sbx-11:main:g 6:fix/sbx-13:fix/sbx-11:r 8:fix/sbx-14:fix/sbx-13:g)"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$(tail -n 1 <<<"$output")" = fix/sbx-14 ]
  [ "$(skipped)" = "" ]
  case "$output" in *"checks failing"*) echo "skipped something: $output" >&2; return 1 ;; esac
}

@test "stack-base: red leaves down to a shared green PR stack on it; all red stacks on the base branch (B1 f)" {
  other_run_branch fix/sbx-11 main a.txt a
  plan_branch sbx-11
  plan_branch sbx-13
  plan_branch sbx-14
  pr_list "$(prs 5:fix/sbx-11:main:g 6:fix/sbx-13:fix/sbx-11:r 7:fix/sbx-14:fix/sbx-11:r)"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$(tail -n 1 <<<"$output")" = fix/sbx-11 ]
  [ "$(skipped)" = "6,7" ]
  : >"$GH_STUB_RESPONSES/map"
  pr_list "$(prs 5:fix/sbx-11:main:r 6:fix/sbx-13:fix/sbx-11:r 7:fix/sbx-14:fix/sbx-11:r)"
  ns-ledger set "$LEDGER" '.stacked_on = null'
  git -C "$CODE_WT" reset -q --hard origin/main
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$(tail -n 1 <<<"$output")" = main ]
  [ "$(skipped)" = "5,6,7" ]
}

# review S1: a PR already merged into the code branch is never skipped, nor anything below it
@test "stack-base rerun keeps the PR it already merged even when its checks turned red (S1)" {
  other_run_branch fix/sbx-11 main a.txt a
  other_run_branch fix/sbx-13 fix/sbx-11 b.txt b
  plan_branch sbx-11
  plan_branch sbx-13
  pr_list "$(prs 5:fix/sbx-11:main:g 6:fix/sbx-13:fix/sbx-11:g)"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$(tail -n 1 <<<"$output")" = fix/sbx-13 ]
  : >"$GH_STUB_RESPONSES/map"
  pr_list "$(prs 5:fix/sbx-11:main:g 6:fix/sbx-13:fix/sbx-11:r)"
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$(tail -n 1 <<<"$output")" = fix/sbx-13 ]
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = sbx-13 ]
  [ "$(skipped)" = "" ]
}

# review S2: a chain whose bottom targets a closed run branch belongs to the base that closed PR targeted
@test "stack-base ignores a chain whose closed base PR targeted another base branch (S2)" {
  plan_branch sbx-15
  pr_list "$(prs 8:fix/sbx-15:fix/sbx-11:g)"
  pr_closed '[{"number":4,"headRefName":"fix/sbx-11","baseRefName":"e2e/old","state":"CLOSED","mergedAt":null,"closedAt":"2026-10-02T23:00:00Z"}]'
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$(tail -n 1 <<<"$output")" = main ]
  [ "$(ns-ledger get "$LEDGER" .stacked_on)" = main ]
  run ns stack sbx
  assert_success
  assert_output_contains "1 open run PRs target other base branches"
  assert_output_contains "no open run PRs"
}

@test "ns stack still marks a closed base whose PR targeted the base branch (S2)" {
  plan_branch sbx-15
  pr_list "$(prs 8:fix/sbx-15:fix/sbx-11:g)"
  pr_closed '[{"number":4,"headRefName":"fix/sbx-11","baseRefName":"main","state":"CLOSED","mergedAt":null,"closedAt":"2026-10-02T23:00:00Z"}]'
  run ns stack sbx
  assert_success
  assert_output_contains "base closed"
  assert_output_contains "#8"
}

@test "stack-base stacks on a PR whose base PR was merged into the base branch, without a closed warning (S2)" {
  other_run_branch fix/sbx-15 main e.txt e
  plan_branch sbx-15
  pr_list "$(prs 8:fix/sbx-15:fix/sbx-11:g)"
  pr_closed '[{"number":4,"headRefName":"fix/sbx-11","baseRefName":"main","state":"MERGED","mergedAt":"2026-10-02T22:00:00Z","closedAt":"2026-10-02T22:00:00Z"}]'
  run ns-conductor stack-base sbx-12
  assert_success
  [ "$(tail -n 1 <<<"$output")" = fix/sbx-15 ]
  case "$output" in *"ns stack drop"*) echo "false warning: $output" >&2; return 1 ;; esac
}

# review N1: a failed closed search is not silent
@test "stack-base warns when the closed-PR search fails" {
  plan_branch sbx-15
  pr_list "$(prs 8:fix/sbx-15:fix/sbx-11:g)"
  { printf '1\t-\t^api graphql .*ClosedRunPRs\n'; cat "$GH_STUB_RESPONSES/map"; } >"$GH_STUB_RESPONSES/map.new"
  mv "$GH_STUB_RESPONSES/map.new" "$GH_STUB_RESPONSES/map"
  run ns-conductor stack-base sbx-12
  assert_output_contains "could not search the closed PRs"
  # the base of #8 cannot be told without the closed list: gate 1.5
  assert_failure 7
}

# re-review 1: a red PR whose base is unknown is not pruned (it may belong to another base): it escalates
@test "stack-base does not prune a red PR whose base is unknown; it escalates instead" {
  plan_branch sbx-15
  pr_list "$(prs 8:fix/sbx-15:fix/sbx-11:r)"
  pr_closed '[]'
  run ns-conductor stack-base sbx-12
  assert_failure 7
  case "$output" in *"Stacked on"* | *"skipped (checks failing)"*) echo "pruned an unknown-base PR: $output" >&2; return 1 ;; esac
  [ "$(skipped)" = "" ]
}

# re-review 2: ns stack searches the closed PRs once per project
@test "ns stack searches the closed PRs once and warns once when the search fails" {
  plan_branch sbx-15
  pr_list "$(prs 8:fix/sbx-15:fix/sbx-11:g)"
  pr_closed '[{"number":4,"headRefName":"fix/sbx-11","baseRefName":"main","state":"CLOSED","mergedAt":null,"closedAt":"2026-10-02T23:00:00Z"}]'
  run ns stack sbx
  assert_success
  assert_output_contains "base closed"
  [ "$(grep -c "ClosedRunPRs" "$GH_STUB_LOG")" -eq 1 ]
  : >"$GH_STUB_RESPONSES/map"
  pr_list "$(prs 8:fix/sbx-15:fix/sbx-11:g)"
  { printf '1\t-\t^api graphql .*ClosedRunPRs\n'; cat "$GH_STUB_RESPONSES/map"; } >"$GH_STUB_RESPONSES/map.new"
  mv "$GH_STUB_RESPONSES/map.new" "$GH_STUB_RESPONSES/map"
  run ns stack sbx
  [ "$(grep -c "could not search the closed PRs" <<<"$output")" -eq 1 ]
}

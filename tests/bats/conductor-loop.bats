#!/usr/bin/env bats

load helpers

fixture_vars() {
  FIX="$BATS_TEST_TMPDIR/fixture"
  BARE="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  RUNDIR="$WT/.nightshift/runs/sbx-12"
  LEDGER="$RUNDIR/ledger.yaml"
  FWT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12--feature"
}

# the slow part of the setup, run once per file (ns_cached_fixture)
fixture_build() {
  fixture_vars
  mkdir -p "$FIX/.claude"
  printf '# sandbox\n' >"$FIX/README.md"
  write_profile_to "$FIX/.claude/project-profile.yaml" true
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T2 --yes >/dev/null
}

setup() {
  ns_test_setup
  ns_cached_fixture fixture_build
  fixture_vars
}

write_profile_to() {
  cat >"$1" <<EOF
project: nightshift-sandbox
prefix: sbx
commands:
  setup: "true"
  lint: '${3:-true}'
  test: '$2'
git: {}
stacks: [python]
EOF
}

# set_test_cmd <command>: change the test command on origin/main
set_test_cmd() {
  local c="$BATS_TEST_TMPDIR/profile-clone"
  rm -rf "$c"
  git clone -q "$BARE" "$c"
  write_profile_to "$c/.claude/project-profile.yaml" "$1" "${2:-true}"
  git -C "$c" commit -q -am "profile: test command"
  git -C "$c" push -q origin main
}

lget() { ns-ledger get "$LEDGER" "$1"; }
pstate() { lget "(.phases[] | select(.id == \"$1\") | .$2)"; }
remote_sha() { git -C "$BARE" rev-parse "$1"; }

# commit_plan: a plan document and an acceptance test on plan/sbx-12 (plus the run's ledger commits)
commit_plan() {
  mkdir -p "$WT/docs" "$WT/tests"
  cp "$NS_REPO_ROOT/tests/fixtures/plans/two-phase-plan.md" "$WT/docs/sbx-12-plan.md"
  printf 'def test_acceptance():\n    assert True\n' >"$WT/tests/test_acceptance_sbx12.py"
  git -C "$WT" add docs tests
  git -C "$WT" commit -q -m "plan"
}

# mkphase <phase> <file> <content>: phase branch on origin, cut from origin/feature/12
mkphase() {
  local c="$BATS_TEST_TMPDIR/phase-clone"
  rm -rf "$c"
  git clone -q "$BARE" "$c"
  git -C "$c" checkout -q -b "feature/12--$1" origin/feature/12
  printf '%s\n' "$3" >"$c/$2"
  git -C "$c" add "$2"
  git -C "$c" commit -q -m "add $2"
  git -C "$c" push -q origin "feature/12--$1"
}

# push_phase <phase> <file> <content>: one more commit on origin/feature/12--<phase>
push_phase() {
  local c="$BATS_TEST_TMPDIR/phase-clone"
  rm -rf "$c"
  git clone -q "$BARE" "$c"
  git -C "$c" checkout -q -b "feature/12--$1" "origin/feature/12--$1"
  printf '%s\n' "$3" >"$c/$2"
  git -C "$c" add "$2"
  git -C "$c" commit -q -m "add $2"
  git -C "$c" push -q origin "feature/12--$1"
}

# review_file <phase> <approve|changes>: write RUN/review-<phase>-<n>.md for the next round
# (n = review_rounds + 1), its last line the verdict and the current head of the phase branch
# (created on origin from main when missing, for tests that only count rounds)
review_file() {
  local n
  n=$(lget "[.phases[] | select(.id == \"$1\") | .review_rounds] | (.[0] // 0)")
  n=$((n + 1))
  git -C "$BARE" rev-parse -q --verify "refs/heads/feature/12--$1" >/dev/null || git -C "$BARE" branch "feature/12--$1" main
  printf -- '- non-blocking · README.md:1 · nothing · none\n\nREVIEW verdict=%s head=%s\n' "$2" "$(remote_sha "feature/12--$1")" >"$RUNDIR/review-$1-$n.md"
}

# review_phase <phase> <approve|changes>: review_file, then count the round
review_phase() {
  review_file "$1" "$2"
  ns-conductor review-round sbx-12 "$1" "$2" >/dev/null
}

@test "--help lists the new subcommands and an unknown one still exits 2" {
  run ns-conductor --help
  assert_success
  assert_output_contains "  merge  "
  assert_output_contains "  unpause  "
  run ns-conductor frobnicate sbx-12
  assert_failure 2
}

@test "fix-branch creates fix/<id> from origin/main, sets feature_branch and is idempotent" {
  "$NS_REPO_ROOT/bin/ns" new sbx-13 --tier T1 --yes >/dev/null
  L13="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-13/.nightshift/runs/sbx-13/ledger.yaml"
  run ns-conductor fix-branch sbx-13
  assert_success
  dir="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-13--fix"
  [ "$output" = "$dir" ]
  [ "$(git -C "$dir" rev-parse --abbrev-ref HEAD)" = fix/sbx-13 ]
  [ "$(git -C "$dir" rev-parse HEAD)" = "$(remote_sha main)" ]
  [ "$(ns-ledger get "$L13" .feature_branch)" = fix/sbx-13 ]
  before=$(ns-ledger get "$L13" '.events | length')
  run ns-conductor fix-branch sbx-13
  assert_success
  [ "$output" = "$dir" ]
  [ "$(git -C "$dir" rev-parse HEAD)" = "$(remote_sha main)" ]
  [ "$(ns-ledger get "$L13" '.events | length')" = "$before" ]
}

@test "feature cuts feature/12, copies plan and tests in one commit, pushes without ledger or .nightshift" {
  commit_plan
  git -C "$WT" log --format=%s | grep -q '^ns-ledger:'
  run ns-conductor feature sbx-12
  assert_success
  [ "$output" = "$FWT" ]
  [ "$(lget .feature_branch)" = feature/12 ]
  [ -f "$FWT/docs/sbx-12-plan.md" ]
  [ -f "$FWT/tests/test_acceptance_sbx12.py" ]
  [ "$(git -C "$FWT" log origin/main..HEAD --format=%s)" = "ns: plan and acceptance tests for sbx-12" ]
  [ "$(remote_sha feature/12)" = "$(git -C "$FWT" rev-parse HEAD)" ]
  run git -C "$BARE" log feature/12 --format=%s
  assert_success
  assert_output_not_contains "ns-ledger:"
  run git -C "$BARE" ls-tree -r --name-only feature/12
  assert_success
  assert_output_not_contains ".nightshift/"
  assert_output_contains "docs/sbx-12-plan.md"
  # rerun changes nothing
  head=$(remote_sha feature/12)
  run ns-conductor feature sbx-12
  assert_success
  [ "$(remote_sha feature/12)" = "$head" ]
  [ "$(git -C "$FWT" log origin/main..HEAD --format=%s | wc -l)" = 1 ]
}

@test "checks prints PASS lines and runs in the --fix worktree for T1" {
  "$NS_REPO_ROOT/bin/ns" new sbx-13 --tier T1 --yes >/dev/null
  set_test_cmd "pwd >$BATS_TEST_TMPDIR/cwd"
  ns-conductor fix-branch sbx-13 >/dev/null
  run ns-conductor checks sbx-13 feature
  assert_success
  assert_output_contains "PASS python lint"
  assert_output_contains "PASS python test"
  [ "$(cat "$BATS_TEST_TMPDIR/cwd")" = "$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-13--fix" ]
  [ -f "$NS_CONFIG_DIR/logs/sbx-13/feature.checks.log" ]
}

@test "checks exits 1 with FAIL python test and the log tail when test fails" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  set_test_cmd "echo boom-output; false"
  run ns-conductor checks sbx-12 feature
  assert_failure 1
  assert_output_contains "PASS python lint"
  assert_output_contains "FAIL python test"
  assert_output_contains "boom-output"
}

@test "checks writes a <target>.checks.rc marker with the exit code" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  rc="$NS_CONFIG_DIR/logs/sbx-12/feature.checks.rc"
  run ns-conductor checks sbx-12 feature
  assert_success
  [ "$(cat "$rc")" = 0 ]
  set_test_cmd "false"
  run ns-conductor checks sbx-12 feature
  assert_failure 1
  [ "$(cat "$rc")" = 1 ]
}

@test "checks removes a stale marker at start and writes 0 when no checks are configured" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  rc="$NS_CONFIG_DIR/logs/sbx-12/feature.checks.rc"
  mkdir -p "$(dirname "$rc")"
  echo 9 >"$rc"
  set_test_cmd "false"
  run ns-conductor checks sbx-12 feature
  assert_failure 1
  [ "$(cat "$rc")" = 1 ]
  c="$BATS_TEST_TMPDIR/nochecks-clone"
  git clone -q "$BARE" "$c"
  sed -i 's/^stacks: .*/stacks: []/' "$c/.claude/project-profile.yaml"
  git -C "$c" commit -q -am "profile: no stacks"
  git -C "$c" push -q origin main
  echo 9 >"$rc"
  run ns-conductor checks sbx-12 feature
  assert_success
  assert_output_contains "no checks configured"
  [ "$(cat "$rc")" = 0 ]
}

@test "checks with no worktree exits non-zero and still writes a non-zero marker" {
  commit_plan
  rc="$NS_CONFIG_DIR/logs/sbx-12/feature.checks.rc"
  run ns-conductor checks sbx-12 feature
  assert_failure
  assert_output_contains "no worktree for feature"
  [ -f "$rc" ]
  [ "$(cat "$rc")" -ne 0 ]
}

@test "checks run in a clean env: no NS_* variable reaches a check (ns-45)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  set_test_cmd 'test -z "${NS_RUN_ID:-}" && test -z "${NS_LEDGER:-}"'
  NS_RUN_ID=sbx-12 NS_LEDGER="$LEDGER" run ns-conductor checks sbx-12 feature
  assert_success
  assert_output_contains "PASS python test"
}

@test "checks: pytest exit 5 (no tests collected) is SKIP, not FAIL, and exits 0 (ns-45)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  set_test_cmd "exit 5"
  run ns-conductor checks sbx-12 feature
  assert_success
  assert_output_contains "SKIP python test"
  assert_output_not_contains "FAIL"
  [ "$(cat "$NS_CONFIG_DIR/logs/sbx-12/feature.checks.rc")" = 0 ]
}

@test "checks: a python lint command exiting 5 is FAIL, not SKIP (ns-45)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  set_test_cmd "true" "exit 5"
  run ns-conductor checks sbx-12 feature
  assert_failure 1
  assert_output_contains "FAIL python lint"
  assert_output_not_contains "SKIP"
}

@test "checks: a die in the body and a failing check both leave a non-zero marker (ns-45)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  rc="$NS_CONFIG_DIR/logs/sbx-12/feature.checks.rc"
  set_test_cmd "exit 3"
  run ns-conductor checks sbx-12 feature
  assert_failure 1
  [ "$(cat "$rc")" = 1 ]
  git -C "$WT" worktree remove --force "$FWT"
  run ns-conductor checks sbx-12 feature
  assert_failure
  [ "$(cat "$rc")" -ne 0 ]
}

@test "report accepts a short sha prefix of the real head and rejects a non-prefix (ns-45)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  head=$(remote_sha feature/12--p1-alpha)
  mkdir -p "$NS_CONFIG_DIR/logs/sbx-12"
  log="$NS_CONFIG_DIR/logs/sbx-12/p1-alpha.jsonl"
  sed "s/HEAD_PLACEHOLDER/${head:0:7}/" "$NS_REPO_ROOT/tests/fixtures/conductor/report-done.jsonl" >"$log"
  run ns-conductor report sbx-12 p1-alpha
  assert_success
  sed "s/HEAD_PLACEHOLDER/${head:0:6}/" "$NS_REPO_ROOT/tests/fixtures/conductor/report-done.jsonl" >"$log"
  run ns-conductor report sbx-12 p1-alpha
  assert_failure 1
  assert_output_contains "head mismatch"
  sed "s/HEAD_PLACEHOLDER/deadbee/" "$NS_REPO_ROOT/tests/fixtures/conductor/report-done.jsonl" >"$log"
  run ns-conductor report sbx-12 p1-alpha
  assert_failure 1
  assert_output_contains "head mismatch"
}

@test "merge of an already merged phase with a long history says already merged (ns-45)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  # a commit with a huge message, older than the merge: git log keeps writing after grep -q exits
  head -c 400000 /dev/zero | tr '\0' 'x' | fold -w 100 >"$BATS_TEST_TMPDIR/bigmsg"
  git -C "$FWT" commit -q --allow-empty -F "$BATS_TEST_TMPDIR/bigmsg"
  git -C "$FWT" push -q origin HEAD:feature/12
  mkphase p1-alpha a.txt alpha
  review_phase p1-alpha approve
  run ns-conductor merge sbx-12 p1-alpha
  assert_success
  head=$(remote_sha feature/12)
  run ns-conductor merge sbx-12 p1-alpha
  assert_success
  [ "$output" = "already merged" ]
  [ "$(remote_sha feature/12)" = "$head" ]
}

@test "report exits 0 for a matching done report, 1 for a head mismatch and for blocked" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  head=$(remote_sha feature/12--p1-alpha)
  mkdir -p "$NS_CONFIG_DIR/logs/sbx-12"
  log="$NS_CONFIG_DIR/logs/sbx-12/p1-alpha.jsonl"
  sed "s/HEAD_PLACEHOLDER/$head/" "$NS_REPO_ROOT/tests/fixtures/conductor/report-done.jsonl" >"$log"
  run ns-conductor report sbx-12 p1-alpha
  assert_success
  assert_output_contains "PHASE-REPORT p1-alpha status=done head=$head"
  assert_output_contains "nothing left undone"
  sed "s/HEAD_PLACEHOLDER/0000000000000000000000000000000000000000/" "$NS_REPO_ROOT/tests/fixtures/conductor/report-done.jsonl" >"$log"
  run ns-conductor report sbx-12 p1-alpha
  assert_failure 1
  assert_output_contains "head mismatch"
  sed "s/HEAD_PLACEHOLDER/$head/" "$NS_REPO_ROOT/tests/fixtures/conductor/report-blocked.jsonl" >"$log"
  run ns-conductor report sbx-12 p1-alpha
  assert_failure 1
  assert_output_contains "status=blocked"
}

@test "review-round counts rounds; a T2 approve on round 3 does not escalate" {
  run ns-conductor review-round sbx-12 p1-alpha changes
  assert_success
  assert_output_contains "review round 1 of 3"
  run ns-conductor review-round sbx-12 p1-alpha changes
  assert_success
  review_file p1-alpha approve
  run ns-conductor review-round sbx-12 p1-alpha approve
  assert_success
  assert_output_contains "review round 3 of 3"
  [ "$(pstate p1-alpha review_rounds)" = 3 ]
  [ "$(lget '[.events[] | select(.type == "review")] | length')" = 3 ]
  [ "$(lget '[.events[] | select(.type == "review")] | last | .note')" = "p1-alpha round 3 approve" ]
}

@test "review-round: a T2 changes verdict on round 3 exits 7 without a fourth review" {
  ns-conductor review-round sbx-12 p1-alpha changes >/dev/null
  ns-conductor review-round sbx-12 p1-alpha changes >/dev/null
  run ns-conductor review-round sbx-12 p1-alpha changes
  assert_failure 7
  assert_output_contains "round 3"
  assert_output_contains "cap of 3"
  [ "$(pstate p1-alpha review_rounds)" = 3 ]
  [ "$(lget '[.events[] | select(.type == "review")] | length')" = 3 ]
}

@test "review-round honours a configured cap exactly" {
  local c="$BATS_TEST_TMPDIR/profile-clone"
  git clone -q "$BARE" "$c"
  printf 'budgets:\n  T2: {hours: 8, review_rounds: 2}\n' >>"$c/.claude/project-profile.yaml"
  git -C "$c" commit -q -am "profile: two review rounds"
  git -C "$c" push -q origin main
  run ns-conductor review-round sbx-12 p1-alpha changes
  assert_success
  assert_output_contains "review round 1 of 2"
  run ns-conductor review-round sbx-12 p1-alpha changes
  assert_failure 7
  assert_output_contains "cap of 2"
  run ns-conductor review-round sbx-12 p2-beta changes
  assert_success
  review_file p2-beta approve
  run ns-conductor review-round sbx-12 p2-beta approve
  assert_success
  assert_output_contains "review round 2 of 2"
}

@test "review-round: after the cap, approve still exits 0 and changes escalates again" {
  ns-conductor review-round sbx-12 p1-alpha changes >/dev/null
  ns-conductor review-round sbx-12 p1-alpha changes >/dev/null
  run ns-conductor review-round sbx-12 p1-alpha changes
  assert_failure 7
  run ns-conductor review-round sbx-12 p1-alpha changes
  assert_failure 7
  review_file p1-alpha approve
  run ns-conductor review-round sbx-12 p1-alpha approve
  assert_success
  assert_output_contains "review round 5 of 3"
}

@test "unpause clears the budget pause and paused_until" {
  ns-ledger set "$LEDGER" '.budget.paused = true | .budget.paused_until = "2026-10-02T23:00:00Z"'
  run ns-conductor unpause sbx-12
  assert_success
  [ "$(lget .budget.paused)" = false ]
  [ "$(lget '.budget.paused_until // "none"')" = none ]
}

@test "review-round needs a verdict of approve or changes" {
  run ns-conductor review-round sbx-12 p1-alpha
  assert_failure 2
  run ns-conductor review-round sbx-12 p1-alpha maybe
  assert_failure 2
  [ "$(lget '[.events[] | select(.type == "review")] | length')" = 0 ]
}

@test "merge makes a --no-ff merge with the trailer, pushes, removes the phase worktree, marks merged" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  PWT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12--p1-alpha"
  git -C "$WT" fetch -q origin
  git -C "$WT" worktree add -q -b feature/12--p1-alpha "$PWT" origin/feature/12--p1-alpha
  review_phase p1-alpha approve
  run ns-conductor merge sbx-12 p1-alpha
  assert_success
  assert_output_contains "PASS python test"
  [ "$(git -C "$BARE" rev-list --parents -n1 feature/12 | wc -w)" = 3 ]
  git -C "$BARE" log -1 feature/12 --format=%B | grep -qx 'Plan-Phase: p1-alpha'
  [ "$(remote_sha feature/12)" = "$(git -C "$FWT" rev-parse HEAD)" ]
  [ ! -d "$PWT" ]
  [ "$(pstate p1-alpha state)" = merged ]
  head=$(remote_sha feature/12)
  run ns-conductor merge sbx-12 p1-alpha
  assert_success
  [ "$output" = "already merged" ]
  [ "$(remote_sha feature/12)" = "$head" ]
}

@test "merge with a conflict exits 1, leaves no merge in progress and the feature unchanged" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha conflict.txt B
  printf 'A\n' >"$FWT/conflict.txt"
  git -C "$FWT" add conflict.txt
  git -C "$FWT" commit -q -m "feature side"
  git -C "$FWT" push -q origin HEAD:feature/12
  head=$(remote_sha feature/12)
  review_phase p1-alpha approve
  run ns-conductor merge sbx-12 p1-alpha
  assert_failure 1
  assert_output_contains "conflict"
  [ ! -e "$(git -C "$FWT" rev-parse --git-path MERGE_HEAD)" ]
  [ "$(git -C "$FWT" rev-parse HEAD)" = "$head" ]
  [ "$(remote_sha feature/12)" = "$head" ]
  [ -z "$(git -C "$FWT" status --porcelain)" ]
}

@test "merge with failing checks after the merge exits 1 and pushes nothing" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  head=$(remote_sha feature/12)
  set_test_cmd "false"
  review_phase p1-alpha approve
  run ns-conductor merge sbx-12 p1-alpha
  assert_failure 1
  assert_output_contains "FAIL python test"
  [ "$(remote_sha feature/12)" = "$head" ]
  [ "$(git -C "$FWT" rev-parse HEAD)" = "$head" ]
  [ "$(pstate p1-alpha state)" != merged ]
}

@test "gate sets waiting and the gate, and puts the file on the desk" {
  printf '# Plan\n' >"$RUNDIR/plan.md"
  run ns-conductor gate sbx-12 1 RUN/plan.md
  assert_success
  [ "$(lget .state)" = waiting ]
  [ "$(lget .gate)" = 1 ]
  [ "$(lget '.events[] | select(.type == "gate") | .type')" = gate ]
  [ -f "$NS_DESK_DIR/nightshift-sandbox/runs/sbx-12/plan.md" ]
  run ns-conductor gate sbx-12 3 RUN/plan.md
  assert_failure 2
}

@test "finish on T2 sets pr, done, gate 2 and publishes the handoff" {
  printf '<html><body>handoff</body></html>\n' >"$RUNDIR/handoff.html"
  run ns-conductor finish sbx-12 --pr https://github.com/andras-tkcs/nightshift-sandbox/pull/1
  assert_success
  [ "$(lget .state)" = done ]
  [ "$(lget .gate)" = 2 ]
  [ "$(lget .step)" = done ]
  [ "$(lget .pr)" = https://github.com/andras-tkcs/nightshift-sandbox/pull/1 ]
  [ -f "$NS_DESK_DIR/nightshift-sandbox/runs/sbx-12/handoff.html" ]
}

@test "finish on T0 leaves the gate null" {
  "$NS_REPO_ROOT/bin/ns" new sbx-14 --tier T0 --yes >/dev/null
  L14="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-14/.nightshift/runs/sbx-14/ledger.yaml"
  run ns-conductor finish sbx-14 --pr https://github.com/andras-tkcs/nightshift-sandbox/pull/2
  assert_success
  [ "$(ns-ledger get "$L14" .state)" = done ]
  [ "$(ns-ledger get "$L14" '.gate // "null"')" = null ]
  [ "$(ns-ledger get "$L14" .pr)" = https://github.com/andras-tkcs/nightshift-sandbox/pull/2 ]
}

@test "pause and unpause flip budget.paused and add events" {
  run ns-conductor pause sbx-12
  assert_success
  [ "$(lget .budget.paused)" = true ]
  [ "$(lget '.events[-1].type')" = usage-pause ]
  run ns-conductor unpause sbx-12
  assert_success
  [ "$(lget .budget.paused)" = false ]
  [ "$(lget '.events[-1].type')" = usage-resume ]
}

@test "note appends numbered lines to RUN/notes.md, adds a note event and never calls gh (ns-47)" {
  run ns-conductor note sbx-12 "first follow-up"
  assert_success
  [ "$output" = "note 1" ]
  run ns-conductor note sbx-12 "second follow-up"
  assert_success
  [ "$output" = "note 2" ]
  [ "$(sed -n 1p "$RUNDIR/notes.md")" = "1. first follow-up" ]
  [ "$(sed -n 2p "$RUNDIR/notes.md")" = "2. second follow-up" ]
  [ "$(lget '[.events[] | select(.type == "note")] | length')" = 2 ]
  printf 'from a file\n' >"$BATS_TEST_TMPDIR/n.txt"
  run ns-conductor note sbx-12 --file "$BATS_TEST_TMPDIR/n.txt"
  assert_success
  [ "$output" = "note 3" ]
  [ "$(sed -n 3p "$RUNDIR/notes.md")" = "3. from a file" ]
}

@test "note numbers from 1 when notes.md has only a heading (ns-47)" {
  printf '# Notes\n' >"$RUNDIR/notes.md"
  run ns-conductor note sbx-12 "first"
  assert_success
  [ "$output" = "note 1" ]
  [ "$(sed -n 2p "$RUNDIR/notes.md")" = "1. first" ]
}

@test "report --rerun regenerates the result record from origin and validates it (ns-47)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  head=$(remote_sha feature/12--p1-alpha)
  run ns-conductor report sbx-12 p1-alpha --rerun
  assert_success
  assert_output_contains "PHASE-REPORT p1-alpha status=done head=$head"
  assert_output_contains "regenerated by report --rerun"
  log="$NS_CONFIG_DIR/logs/sbx-12/p1-alpha.jsonl"
  [ "$(jq -R -c 'fromjson? | select(.type == "result")' "$log" | wc -l)" = 1 ]
}

@test "report --rerun fails when the phase branch is missing (ns-47)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  run ns-conductor report sbx-12 p1-alpha --rerun
  assert_failure 1
  assert_output_contains "does not exist"
}

@test "report --rerun refuses a phase branch with no commits beyond the feature branch (ns-71)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  git -C "$BARE" branch feature/12--p1-alpha feature/12
  run ns-conductor report sbx-12 p1-alpha --rerun
  assert_failure 1
  assert_output_contains "no changes of its own"
  [ ! -f "$NS_CONFIG_DIR/logs/sbx-12/p1-alpha.jsonl" ]
  [ "$(lget '[.events[] | select(.type == "report-rerun")] | length')" = 0 ]
  # the feature branch moved on and the phase branch is behind it: still nothing of the worker's
  git -C "$FWT" commit -q --allow-empty -m "other phase"
  git -C "$FWT" push -q origin HEAD:feature/12
  run ns-conductor report sbx-12 p1-alpha --rerun
  assert_failure 1
  assert_output_contains "no changes of its own"
  [ ! -f "$NS_CONFIG_DIR/logs/sbx-12/p1-alpha.jsonl" ]
}

@test "report --rerun adds a report-rerun event that ns status and the run report show (ns-71)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  head=$(remote_sha feature/12--p1-alpha)
  ns-ledger set "$LEDGER" '.phases = [{id: "p1-alpha", title: "alpha", state: "review", branch: "feature/12--p1-alpha", worktree: null, attempts: 1, review_rounds: 0}]'
  run ns-conductor report sbx-12 p1-alpha --rerun
  assert_success
  [ "$(lget '[.events[] | select(.type == "report-rerun") | .note] | .[0]')" = "p1-alpha $head" ]
  run "$NS_REPO_ROOT/bin/ns" status sbx-12
  assert_success
  assert_output_contains "report-rerun  p1-alpha $head"
  assert_output_contains "attempts 1  rounds 0  report regenerated"
  run "$NS_REPO_ROOT/bin/ns" report sbx-12
  assert_success
  grep -qF 'Phase reports regenerated by `ns-conductor report --rerun`, not written by the worker:' "$RUNDIR/run-report.md"
  grep -qE "^- [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}: p1-alpha at ${head:0:12}\$" "$RUNDIR/run-report.md"
}

@test "review-round records the verdict and the reviewed head (ns-71)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  head=$(remote_sha feature/12--p1-alpha)
  review_phase p1-alpha changes
  [ "$(pstate p1-alpha review_verdict)" = changes ]
  [ "$(pstate p1-alpha reviewed_head)" = "$head" ]
  review_phase p1-alpha approve
  [ "$(pstate p1-alpha review_verdict)" = approve ]
  [ "$(lget '.events[-1].note')" = "p1-alpha round 2 approve" ]
  run "$NS_REPO_ROOT/bin/ns" status sbx-12
  assert_output_contains "rounds 2  review approve ${head:0:12}"
  # no review file for round 3: an approval is refused and records nothing (exit 9) ...
  run ns-conductor review-round sbx-12 p1-alpha approve
  assert_failure 9
  assert_output_contains "review-p1-alpha-3.md does not exist"
  assert_output_contains "never edit the review file"
  [ "$(pstate p1-alpha review_rounds)" = 2 ]
  # ... and changes needs no file: the argument is the verdict (changes at the T2 cap exits 7)
  run ns-conductor review-round sbx-12 p1-alpha changes
  assert_failure 7
  [ "$(pstate p1-alpha review_verdict)" = changes ]
  [ "$(pstate p1-alpha review_rounds)" = 3 ]
}

@test "review-round refuses a verdict that contradicts RUN/review-<phase>-<n>.md and records nothing (ns-71)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  printf -- '- blocking · a.txt:1 · wrong · fix it\n\nREVIEW verdict=changes\n' >"$RUNDIR/review-p1-alpha-1.md"
  events=$(lget '.events | length')
  run ns-conductor review-round sbx-12 p1-alpha approve
  assert_failure 9
  assert_output_contains "not verdict approve"
  [ "$(lget '.events | length')" = "$events" ]
  [ "$(lget '[.phases[] | select(.id == "p1-alpha")] | length')" = 0 ]
  run ns-conductor merge sbx-12 p1-alpha
  assert_failure 8
  # an approval needs a verdict line when the review file exists
  printf -- '- non-blocking · a.txt:1 · fine · none\n' >"$RUNDIR/review-p1-alpha-1.md"
  run ns-conductor review-round sbx-12 p1-alpha approve
  assert_failure 9
  assert_output_contains "no REVIEW verdict line"
  # the matching verdict is recorded (CRLF line ends and trailing blank lines are fine)
  printf -- '- non-blocking · a.txt:1 · fine · none\r\n\r\nREVIEW verdict=approve head=%s\r\n\r\n\n' "$(remote_sha feature/12--p1-alpha)" >"$RUNDIR/review-p1-alpha-1.md"
  run ns-conductor review-round sbx-12 p1-alpha approve
  assert_success
  [ "$(pstate p1-alpha review_verdict)" = approve ]
}

@test "merge refuses without an approved review of the current phase head (ns-71)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  fhead=$(remote_sha feature/12)
  run ns-conductor merge sbx-12 p1-alpha
  assert_failure 8
  assert_output_contains "no approved review"
  [ "$(remote_sha feature/12)" = "$fhead" ]
  review_phase p1-alpha changes
  run ns-conductor merge sbx-12 p1-alpha
  assert_failure 8
  [ "$(remote_sha feature/12)" = "$fhead" ]
  [ "$(pstate p1-alpha state)" != merged ]
  review_phase p1-alpha approve
  run ns-conductor merge sbx-12 p1-alpha
  assert_success
  [ "$(pstate p1-alpha state)" = merged ]
}

@test "approve head A, push head B, report --rerun: merge refuses until a new round approves B (ns-71)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  a=$(remote_sha feature/12--p1-alpha)
  review_phase p1-alpha approve
  [ "$(pstate p1-alpha reviewed_head)" = "$a" ]
  push_phase p1-alpha b.txt beta
  b=$(remote_sha feature/12--p1-alpha)
  [ "$a" != "$b" ]
  run ns-conductor report sbx-12 p1-alpha --rerun
  assert_success
  fhead=$(remote_sha feature/12)
  run ns-conductor merge sbx-12 p1-alpha
  assert_failure 8
  assert_output_contains "no approved review"
  assert_output_contains "${b:0:12}"
  [ "$(remote_sha feature/12)" = "$fhead" ]
  [ "$(pstate p1-alpha state)" != merged ]
  review_phase p1-alpha approve
  [ "$(pstate p1-alpha reviewed_head)" = "$b" ]
  run ns-conductor merge sbx-12 p1-alpha
  assert_success
  git -C "$BARE" merge-base --is-ancestor "$b" feature/12
}

@test "review-round approve needs RUN/review-<phase>-<n>.md of this round ending with verdict approve (ns-71)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  head=$(remote_sha feature/12--p1-alpha)
  events=$(lget '.events | length')
  run ns-conductor review-round sbx-12 p1-alpha approve
  assert_failure 9
  assert_output_contains "review-p1-alpha-1.md"
  [ "$(lget '.events | length')" = "$events" ]
  # a file for another round (off by one) does not count
  printf 'REVIEW verdict=approve head=%s\n' "$head" >"$RUNDIR/review-p1-alpha-2.md"
  run ns-conductor review-round sbx-12 p1-alpha approve
  assert_failure 9
  [ "$(lget '.events | length')" = "$events" ]
  # changes needs no file
  run ns-conductor review-round sbx-12 p1-alpha changes
  assert_success
  [ "$(pstate p1-alpha review_verdict)" = changes ]
}

@test "review-round refuses an approval whose head= is missing or not the current phase head (ns-71)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  a=$(remote_sha feature/12--p1-alpha)
  printf 'REVIEW verdict=approve\n' >"$RUNDIR/review-p1-alpha-1.md"
  run ns-conductor review-round sbx-12 p1-alpha approve
  assert_failure 9
  assert_output_contains "head="
  # the reviewer saw head A, the branch moved to B before the round was counted
  push_phase p1-alpha b.txt beta
  printf 'REVIEW verdict=approve head=%s\n' "$a" >"$RUNDIR/review-p1-alpha-1.md"
  run ns-conductor review-round sbx-12 p1-alpha approve
  assert_failure 9
  assert_output_contains "${a:0:12}"
  [ "$(lget '[.events[] | select(.type == "review")] | length')" = 0 ]
  # a short sha of at least 7 characters of the current head is accepted
  b=$(remote_sha feature/12--p1-alpha)
  printf 'REVIEW verdict=approve head=%s\n' "${b:0:7}" >"$RUNDIR/review-p1-alpha-1.md"
  run ns-conductor review-round sbx-12 p1-alpha approve
  assert_success
  [ "$(pstate p1-alpha reviewed_head)" = "$b" ]
}

@test "review-round names a malformed head= and still sees the verdict in that line (ns-71 review)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  local bad
  for bad in ABCDEF1 abc '' abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab; do
    printf 'REVIEW verdict=approve head=%s\n' "$bad" >"$RUNDIR/review-p1-alpha-1.md"
    run ns-conductor review-round sbx-12 p1-alpha approve
    assert_failure 9
    assert_output_contains "is not 7 to 64 lowercase hex"
    # the verdict is still read, so `changes` contradicts the file
    run ns-conductor review-round sbx-12 p1-alpha changes
    assert_failure 9
    assert_output_contains "not verdict changes"
  done
  [ "$(lget '[.events[] | select(.type == "review")] | length')" = 0 ]
}

@test "merge refuses a phase branch with no changes of its own (ns-71)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  git -C "$BARE" branch feature/12--p1-alpha feature/12
  review_phase p1-alpha approve
  fhead=$(remote_sha feature/12)
  run ns-conductor merge sbx-12 p1-alpha
  assert_failure 1
  assert_output_contains "no changes of its own"
  [ "$(remote_sha feature/12)" = "$fhead" ]
  [ "$(pstate p1-alpha state)" != merged ]
  # behind the feature branch: still nothing of its own
  git -C "$FWT" commit -q --allow-empty -m "other phase"
  git -C "$FWT" push -q origin HEAD:feature/12
  fhead=$(remote_sha feature/12)
  review_phase p1-alpha approve
  run ns-conductor merge sbx-12 p1-alpha
  assert_failure 1
  assert_output_contains "no changes of its own"
  [ "$(remote_sha feature/12)" = "$fhead" ]
  [ "$(pstate p1-alpha state)" != merged ]
}

@test "report --rerun refuses commits that change nothing (ns-71)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  c="$BATS_TEST_TMPDIR/phase-clone"
  git -C "$c" rm -q a.txt
  git -C "$c" commit -q -m "drop a.txt"
  git -C "$c" push -q origin feature/12--p1-alpha
  run ns-conductor report sbx-12 p1-alpha --rerun
  assert_failure 1
  assert_output_contains "no changes of its own"
  [ ! -f "$NS_CONFIG_DIR/logs/sbx-12/p1-alpha.jsonl" ]
}

@test "review-round fix of a T1 run checks the approval against the fix branch head (ns-71)" {
  "$NS_REPO_ROOT/bin/ns" new sbx-13 --tier T1 --yes >/dev/null
  R13="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-13/.nightshift/runs/sbx-13"
  ns-conductor fix-branch sbx-13 >/dev/null
  fx="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-13--fix"
  printf 'fix\n' >"$fx/fix.txt"
  git -C "$fx" add fix.txt
  git -C "$fx" commit -q -m "fix"
  git -C "$fx" push -q origin HEAD:refs/heads/fix/sbx-13
  head=$(remote_sha fix/sbx-13)
  run ns-conductor review-round sbx-13 fix approve
  assert_failure 9
  assert_output_contains "review-fix-1.md"
  printf 'REVIEW verdict=approve head=%s\n' "$head" >"$R13/review-fix-1.md"
  run ns-conductor review-round sbx-13 fix approve
  assert_success
  [ "$(ns-ledger get "$R13/ledger.yaml" '(.phases[] | select(.id == "fix") | .reviewed_head)')" = "$head" ]
}

@test "checks writes a start and an end line per check into the log, and the run report shows them (#65)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  set_test_cmd "echo collected 0 items; exit 5"
  run ns-conductor checks sbx-12 feature
  assert_success
  log="$NS_CONFIG_DIR/logs/sbx-12/feature.checks.log"
  t='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
  grep -Eq "^== start python lint $t\$" "$log"
  grep -Eq "^== end python lint $t PASS exit 0\$" "$log"
  grep -Eq "^== start python test $t\$" "$log"
  grep -Eq "^== end python test $t SKIP exit 5\$" "$log"
  # the command's output stays between the two lines
  [ "$(sed -n '/^== start python test/,/^== end python test/p' "$log" | grep -c 'collected 0 items')" = 1 ]
  run "$NS_REPO_ROOT/bin/ns" report sbx-12
  assert_success
  grep -Eq '^\| feature \| python lint \| PASS \| [0-9]+s \| ' "$output"
  grep -Eq '^\| feature \| python test \| SKIP \| [0-9]+s \| ' "$output"
  grep -qF 'SKIP (pytest collected no tests' "$output"
}

@test "gate 1.5 keeps the question of RUN/escalation.md in the gate event note (#118)" {
  printf '# Escalation: checks\n\n## Question\nAccept the | failure?\nOr not.\n\n## Owner'"'"'s answer\n' >"$RUNDIR/escalation.md"
  run ns-conductor gate sbx-12 1.5 RUN/escalation.md
  assert_success
  [ "$(lget '[.events[] | select(.type == "gate")][-1].note')" = "gate 1.5: waiting for the owner: Accept the | failure? Or not." ]
  run "$NS_REPO_ROOT/bin/ns" report sbx-12
  assert_success
  grep -qF '(gate 1.5): Accept the \| failure? Or not.' "$output"
}

@test "gate 1 and gate 1.5 without a question keep the plain note (#118)" {
  printf '# Plan\n' >"$RUNDIR/plan.md"
  ns-conductor gate sbx-12 1 RUN/plan.md >/dev/null
  [ "$(lget '[.events[] | select(.type == "gate")][-1].note')" = "gate 1: waiting for the owner" ]
  printf '# Escalation\n\nno question section\n' >"$RUNDIR/escalation.md"
  ns-conductor gate sbx-12 1.5 RUN/escalation.md >/dev/null
  [ "$(lget '[.events[] | select(.type == "gate")][-1].note')" = "gate 1.5: waiting for the owner" ]
}

@test "finish commits and pushes RUN/run-report.md and publishes it next to the handoff (#118)" {
  printf '<html><body>handoff</body></html>\n' >"$RUNDIR/handoff.html"
  run ns-conductor finish sbx-12 --pr https://github.com/andras-tkcs/nightshift-sandbox/pull/1
  assert_success
  git -C "$WT" ls-files --error-unmatch .nightshift/runs/sbx-12/run-report.md >/dev/null
  [ -z "$(git -C "$WT" status --porcelain -- .nightshift/runs/sbx-12/run-report.md)" ]
  git -C "$BARE" show plan/sbx-12:.nightshift/runs/sbx-12/run-report.md | grep -q '^- State: done$'
  [ -f "$NS_DESK_DIR/nightshift-sandbox/runs/sbx-12/run-report.md" ]
  [ -f "$NS_DESK_DIR/nightshift-sandbox/runs/sbx-12/handoff.html" ]
}

@test "finish on T2: a failed handoff publish is fatal, the run report is still committed and published (#118)" {
  printf '<html><script>x()</script></html>\n' >"$RUNDIR/handoff.html"
  run ns-conductor finish sbx-12 --pr https://github.com/andras-tkcs/nightshift-sandbox/pull/1
  assert_failure 1
  assert_output_contains "could not publish the handoff report"
  [ "$(lget .state)" = done ]
  [ "$(lget '.events[-1].type')" = finish ]
  git -C "$BARE" show plan/sbx-12:.nightshift/runs/sbx-12/run-report.md >/dev/null
  [ -f "$NS_DESK_DIR/nightshift-sandbox/runs/sbx-12/run-report.md" ]
  [ ! -f "$NS_DESK_DIR/nightshift-sandbox/runs/sbx-12/handoff.html" ]
}

@test "finish on T2: a failed run report publish only warns, the handoff is published (#118)" {
  printf '<html><body>handoff</body></html>\n' >"$RUNDIR/handoff.html"
  # a directory in the way on the desk: copying the run report fails, the handoff copy does not
  mkdir -p "$NS_DESK_DIR/nightshift-sandbox/runs/sbx-12/run-report.md"
  run ns-conductor finish sbx-12 --pr https://github.com/andras-tkcs/nightshift-sandbox/pull/1
  assert_success
  assert_output_contains "could not publish RUN/run-report.md"
  [ -f "$NS_DESK_DIR/nightshift-sandbox/runs/sbx-12/handoff.html" ]
  [ ! -f "$NS_DESK_DIR/nightshift-sandbox/runs/sbx-12/run-report.md" ]
  git -C "$BARE" show plan/sbx-12:.nightshift/runs/sbx-12/run-report.md >/dev/null
}

@test "gate 1.5: the question in the note has no control characters and is cut at 200 characters, not bytes (#157 review)" {
  long=$(printf 'a%.0s' $(seq 1 199))
  printf '# Escalation\n\n## Question\nWhy\r\tnot \033[31mred?\n%sé more\n' "$long" >"$RUNDIR/escalation.md"
  run ns-conductor gate sbx-12 1.5 RUN/escalation.md
  assert_success
  note=$(lget '[.events[] | select(.type == "gate")][-1].note')
  python3 - "$note" <<'PY2'
import sys
q = sys.argv[1].split("waiting for the owner: ", 1)[1]
assert not any(ord(c) < 32 or ord(c) == 127 for c in q), repr(q)
assert len(q) == 200, len(q)
assert q.startswith("Why not [31mred? a"), repr(q[:30])
PY2
}

# ---- ns-x5 acceptance tests (RUN/test-strategy.md of ns-x5) ----

# x5_count: how often the counting check command ran (0 when never)
x5_count() {
  if [ -f "$BATS_TEST_TMPDIR/count" ]; then
    echo $(($(wc -l <"$BATS_TEST_TMPDIR/count")))
  else
    echo 0
  fi
}

# x5_wait_count: wait (up to 20 s) until the counting check command has started once
x5_wait_count() {
  local i
  for i in $(seq 200); do
    [ ! -s "$BATS_TEST_TMPDIR/count" ] || return 0
    sleep 0.1
  done
  echo "the first checks call never started its check" >&2
  return 1
}

# x5_sbx12: plan, feature worktree and the counting check command (plus an optional tail)
x5_sbx12() {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  set_test_cmd "echo x >>$BATS_TEST_TMPDIR/count${1:-}"
}

# x5_sbx13: a T1 run sbx-13 with its --fix worktree and the counting check command
x5_sbx13() {
  "$NS_REPO_ROOT/bin/ns" new sbx-13 --tier T1 --yes >/dev/null
  set_test_cmd "echo x >>$BATS_TEST_TMPDIR/count${1:-}"
  ns-conductor fix-branch sbx-13 >/dev/null
  XWT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-13--fix"
  L13="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-13/.nightshift/runs/sbx-13/ledger.yaml"
}

# x5_hold: shell text for a check command that blocks until the test creates the release file
x5_hold() {
  echo "while [ ! -e $BATS_TEST_TMPDIR/release ]; do sleep 0.1; done"
}

# x5_two_calls: start a checks call that holds the lock, start a second one, release the first once
# the second says it waits; sets ra, rb (their exit codes) and output (the second call's output)
x5_two_calls() {
  local pa pb i
  ra=0 rb=0
  ns-conductor checks sbx-12 feature >"$BATS_TEST_TMPDIR/a.out" 2>&1 3>&- &
  pa=$!
  x5_wait_count
  ns-conductor checks sbx-12 feature >"$BATS_TEST_TMPDIR/b.out" 2>&1 3>&- &
  pb=$!
  for i in $(seq 200); do
    ! grep -q "another run of feature" "$BATS_TEST_TMPDIR/b.out" || break
    sleep 0.1
  done
  : >"$BATS_TEST_TMPDIR/release"
  wait "$pa" || ra=$?
  wait "$pb" || rb=$?
  output=$(cat "$BATS_TEST_TMPDIR/b.out")
}

# AC-1: a concurrent second call waits and reports the first call's PASS
x5_lock_pass() {
  x5_sbx12 "; $(x5_hold)"
  x5_two_calls
  [ "$(x5_count)" -eq 1 ]
  [ "$ra" -eq 0 ]
  [ "$rb" -eq 0 ]
  assert_output_contains "another run of feature"
  assert_output_contains "result of the concurrent run on tree"
  assert_output_contains "PASS"
}

@test "checks: a concurrent second call waits and reports the first call's PASS (ns-x5)" {
  x5_lock_pass
}

# AC-1: the same with a failing check: both exit 1, the check ran once
x5_lock_fail() {
  x5_sbx12 "; $(x5_hold); false"
  x5_two_calls
  [ "$(x5_count)" -eq 1 ]
  [ "$ra" -eq 1 ]
  [ "$rb" -eq 1 ]
  assert_output_contains "result of the concurrent run on tree"
  assert_output_contains "FAIL"
}

@test "checks: a concurrent second call reports the first call's FAIL and exit code (ns-x5)" {
  x5_lock_fail
}

# AC-1 (D4): a process a check leaves running does not hold the lock
x5_no_lock_leak() {
  local lockf="$NS_CONFIG_DIR/logs/sbx-12/feature.checks.lock" rc=0
  x5_sbx12 "; setsid sleep 30 </dev/null >/dev/null 2>&1 3>&- & echo \$! >$BATS_TEST_TMPDIR/sleep.pid"
  run ns-conductor checks sbx-12 feature
  assert_success
  [ "$(x5_count)" -eq 1 ]
  [ -f "$lockf" ] || rc=1
  [ "$rc" -eq 0 ] && { flock -n "$lockf" true || rc=1; }
  kill "$(cat "$BATS_TEST_TMPDIR/sleep.pid")" 2>/dev/null || true
  [ "$rc" -eq 0 ]
}

@test "checks: a process a check leaves running does not hold the checks lock (ns-x5)" {
  x5_no_lock_leak
}

# AC-1: a lock file left by a killed holder does not block a later call
x5_stale_lock() {
  local lockf="$NS_CONFIG_DIR/logs/sbx-12/feature.checks.lock" pid i
  x5_sbx12
  mkdir -p "$(dirname "$lockf")"
  (
    exec 9>"$lockf"
    flock 9
    exec sleep 60
  ) 3>&- &
  pid=$!
  for i in $(seq 200); do
    flock -n "$lockf" true || break
    sleep 0.1
  done
  ! flock -n "$lockf" true
  kill -9 "$pid"
  wait "$pid" 2>/dev/null || true
  run ns-conductor checks sbx-12 feature
  assert_success
  [ "$(x5_count)" -eq 1 ]
  assert_output_not_contains "waiting"
  # the call went through the locked path of D3 and recorded its result (D6)
  [ -f "$NS_CONFIG_DIR/logs/sbx-12/feature.checks.json" ]
}

@test "checks: a lock left by a killed process does not block a later call (ns-x5)" {
  x5_stale_lock
}

# AC-2: a second call on the same tree is a cache hit
x5_cache_hit() {
  local tree
  x5_sbx12
  run ns-conductor checks sbx-12 feature
  assert_success
  [ "$(x5_count)" -eq 1 ]
  tree=$(git -C "$FWT" rev-parse 'HEAD^{tree}')
  run ns-conductor checks sbx-12 feature
  assert_success
  [ "$(x5_count)" -eq 1 ]
  assert_output_contains "cached PASS for tree $tree"
  [ "$(cat "$NS_CONFIG_DIR/logs/sbx-12/feature.checks.rc")" = 0 ]
}

@test "checks: a second call on the same clean tree is a cache hit and writes rc 0 (ns-x5)" {
  x5_cache_hit
}

# x5_pass_then_hit: one pass and one cache hit (count 1), so a later rerun is caused by the change
x5_pass_then_hit() {
  run ns-conductor checks sbx-12 feature
  assert_success
  run ns-conductor checks sbx-12 feature
  assert_success
  assert_output_contains "cached PASS for tree"
  [ "$(x5_count)" -eq 1 ]
}

# AC-3 (a): a new commit changes the tree
x5_miss_commit() {
  x5_sbx12
  x5_pass_then_hit
  printf 'new\n' >"$FWT/new.txt"
  git -C "$FWT" add new.txt
  git -C "$FWT" commit -q -m "new file"
  run ns-conductor checks sbx-12 feature
  assert_success
  assert_output_not_contains "cached PASS"
  [ "$(x5_count)" -eq 2 ]
}

@test "checks: a new commit reruns the checks (ns-x5)" {
  x5_miss_commit
}

# AC-3 (c): a failure is never a cache hit, but it is recorded (for replay)
x5_miss_failure() {
  x5_sbx12 "; false"
  run ns-conductor checks sbx-12 feature
  assert_failure 1
  run ns-conductor checks sbx-12 feature
  assert_failure 1
  assert_output_not_contains "cached PASS"
  assert_output_not_contains "PASS python test"
  [ "$(x5_count)" -eq 2 ]
  jq -e '.rc == 1 and .target == "feature"' "$NS_CONFIG_DIR/logs/sbx-12/feature.checks.json" >/dev/null
}

@test "checks: an earlier failure reruns the checks and is never reported as a pass (ns-x5)" {
  x5_miss_failure
}

# AC-3 (d): --force reruns
x5_miss_force() {
  x5_sbx12
  x5_pass_then_hit
  run ns-conductor checks sbx-12 feature --force
  assert_success
  assert_output_not_contains "cached PASS"
  [ "$(x5_count)" -eq 2 ]
}

@test "checks: --force reruns the checks after a pass (ns-x5)" {
  x5_miss_force
}

# AC-3 (e): an untracked non-ignored file makes the worktree dirty
x5_miss_untracked() {
  x5_sbx12
  x5_pass_then_hit
  printf 'u\n' >"$FWT/untracked.txt"
  run ns-conductor checks sbx-12 feature
  assert_success
  assert_output_not_contains "cached PASS"
  [ "$(x5_count)" -eq 2 ]
}

@test "checks: an untracked file in the worktree reruns the checks (ns-x5)" {
  x5_miss_untracked
}

# AC-3 (e): a modified tracked file makes the worktree dirty
x5_miss_modified() {
  x5_sbx12
  x5_pass_then_hit
  printf 'x\n' >>"$FWT/README.md"
  run ns-conductor checks sbx-12 feature
  assert_success
  assert_output_not_contains "cached PASS"
  [ "$(x5_count)" -eq 2 ]
}

@test "checks: a modified tracked file reruns the checks (ns-x5)" {
  x5_miss_modified
}

# AC-3 (e), D6: a pass made on a dirty tree is not cacheable; the next clean pass is
x5_dirty_pass_not_cached() {
  x5_sbx12
  printf 'u\n' >"$FWT/untracked.txt"
  run ns-conductor checks sbx-12 feature
  assert_success
  [ "$(x5_count)" -eq 1 ]
  rm -f "$FWT/untracked.txt"
  run ns-conductor checks sbx-12 feature
  assert_success
  assert_output_not_contains "cached PASS"
  [ "$(x5_count)" -eq 2 ]
  run ns-conductor checks sbx-12 feature
  assert_success
  assert_output_contains "cached PASS"
  [ "$(x5_count)" -eq 2 ]
}

@test "checks: a pass made while an untracked file was present is not cached (ns-x5)" {
  x5_dirty_pass_not_cached
}

# D1: for T1, checks <id> fix is checks <id> feature (same lock, cache and log)
x5_canon_fix() {
  local logs="$NS_CONFIG_DIR/logs/sbx-13"
  x5_sbx13
  run ns-conductor checks sbx-13 feature
  assert_success
  [ "$(x5_count)" -eq 1 ]
  run ns-conductor checks sbx-13 fix
  assert_success
  assert_output_contains "cached PASS"
  [ "$(x5_count)" -eq 1 ]
  [ "$(cat "$logs/fix.checks.rc")" = 0 ]
  [ ! -e "$logs/fix.checks.log" ]
}

@test "checks: for a T1 run, checks fix is a cache hit of checks feature (ns-x5)" {
  x5_canon_fix
}

# D1: the code worktree follows feature_branch, not a tier changed after fix-branch
x5_code_wt_after_retier() {
  x5_sbx13 "; pwd >$BATS_TEST_TMPDIR/cwd"
  ns-ledger set "$L13" '.tier = "T2"'
  run ns-conductor checks sbx-13 feature
  assert_success
  [ "$(cat "$BATS_TEST_TMPDIR/cwd")" = "$XWT" ]
}

@test "checks: a run retiered after fix-branch still checks its --fix worktree (ns-x5)" {
  x5_code_wt_after_retier
}

# AC-4: a warning when the worktree lacks the pushed code branch; none when nothing is pushed
x5_wrong_target() {
  local c="$BATS_TEST_TMPDIR/wrong-clone"
  x5_sbx13
  run ns-conductor checks sbx-13 feature
  assert_success
  assert_output_not_contains "warning:"
  git clone -q "$BARE" "$c"
  git -C "$c" checkout -q -b fix/sbx-13 origin/main
  printf 'elsewhere\n' >"$c/elsewhere.txt"
  git -C "$c" add elsewhere.txt
  git -C "$c" commit -q -m "code pushed from elsewhere"
  git -C "$c" push -q origin fix/sbx-13
  run ns-conductor checks sbx-13 feature
  assert_output_contains "warning:"
  assert_output_contains "does not contain origin/fix/sbx-13"
  assert_output_contains "$XWT"
}

@test "checks: warns when the worktree lacks the run's pushed code branch, and not before (ns-x5)" {
  x5_wrong_target
}

# AC-4, D2/D5: merge's internal checks never warn, while an explicit call on the same tree
# warns about the unmerged phase branch
x5_merge_no_warning() {
  local PWT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12--p1-alpha"
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  mkphase p1-alpha a.txt alpha
  mkphase p2-beta b.txt beta
  git -C "$WT" fetch -q origin
  git -C "$WT" worktree add -q -b feature/12--p1-alpha "$PWT" origin/feature/12--p1-alpha
  review_phase p2-beta changes
  review_phase p1-alpha approve
  run ns-conductor merge sbx-12 p1-alpha
  assert_success
  assert_output_contains "PASS python test"
  assert_output_not_contains "warning:"
  run ns-conductor checks sbx-12 feature
  assert_output_contains "warning:"
  assert_output_contains "does not contain origin/feature/12--p2-beta"
}

@test "checks: merge's internal checks print no warning; an explicit call does (ns-x5)" {
  x5_merge_no_warning
}

# D2: --force is the only accepted third argument
x5_usage() {
  x5_sbx12
  run ns-conductor checks sbx-12 feature --force
  assert_success
  [ "$(x5_count)" -eq 1 ]
  run ns-conductor checks sbx-12 feature --bogus
  assert_failure 2
  assert_output_contains "[--force]"
}

@test "checks: accepts --force as the third argument and rejects anything else with exit 2 (ns-x5)" {
  x5_usage
}

@test "checks twice leaves two == run lines in the checks log (ns-x6)" {
  commit_plan
  ns-conductor feature sbx-12 >/dev/null
  ns-conductor checks sbx-12 feature >/dev/null
  ns-conductor checks sbx-12 feature --force >/dev/null
  [ "$(grep -c '^== run ' "$NS_CONFIG_DIR/logs/sbx-12/feature.checks.log")" = 2 ]
}

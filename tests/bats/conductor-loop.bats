#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  FIX="$BATS_TEST_TMPDIR/fixture"
  BARE="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
  mkdir -p "$FIX/.claude"
  printf '# sandbox\n' >"$FIX/README.md"
  write_profile_to "$FIX/.claude/project-profile.yaml" true
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T2 --yes >/dev/null
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  RUNDIR="$WT/.nightshift/runs/sbx-12"
  LEDGER="$RUNDIR/ledger.yaml"
  FWT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12--feature"
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

# review_phase <phase> <approve|changes>: write RUN/review-<phase>-<n>.md for the next round
# (n = review_rounds + 1) with that verdict as its last line, then count the round
review_phase() {
  local n
  n=$(lget "[.phases[] | select(.id == \"$1\") | .review_rounds] | (.[0] // 0)")
  n=$((n + 1))
  printf -- '- non-blocking · README.md:1 · nothing · none\n\nREVIEW verdict=%s\n' "$2" >"$RUNDIR/review-$1-$n.md"
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
  assert_output_contains "no commits"
  [ ! -f "$NS_CONFIG_DIR/logs/sbx-12/p1-alpha.jsonl" ]
  [ "$(lget '[.events[] | select(.type == "report-rerun")] | length')" = 0 ]
  # the feature branch moved on and the phase branch is behind it: still nothing of the worker's
  git -C "$FWT" commit -q --allow-empty -m "other phase"
  git -C "$FWT" push -q origin HEAD:feature/12
  run ns-conductor report sbx-12 p1-alpha --rerun
  assert_failure 1
  assert_output_contains "no commits"
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
  # no review file for round 3: the argument is the verdict (changes at the T2 cap exits 7)
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
  assert_failure 2
  assert_output_contains "not verdict approve"
  [ "$(lget '.events | length')" = "$events" ]
  [ "$(lget '[.phases[] | select(.id == "p1-alpha")] | length')" = 0 ]
  run ns-conductor merge sbx-12 p1-alpha
  assert_failure 8
  # an approval needs a verdict line when the review file exists
  printf -- '- non-blocking · a.txt:1 · fine · none\n' >"$RUNDIR/review-p1-alpha-1.md"
  run ns-conductor review-round sbx-12 p1-alpha approve
  assert_failure 2
  assert_output_contains "no REVIEW verdict line"
  # the matching verdict is recorded
  printf -- '- non-blocking · a.txt:1 · fine · none\n\nREVIEW verdict=approve\n' >"$RUNDIR/review-p1-alpha-1.md"
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

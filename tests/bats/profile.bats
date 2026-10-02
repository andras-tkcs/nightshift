#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  FIX="$NS_REPO_ROOT/tests/fixtures/profiles"
  export NS_AGENTS_DIR="$FIX/agents"
  # shellcheck source=/dev/null
  source "$NS_REPO_ROOT/bin/lib/profile.sh"
  # a scratch repo with a profile we can break
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.claude"
  cp "$FIX/minimal/.claude/project-profile.yaml" "$REPO/.claude/"
}

prof() { printf '%s\n' "$1" >"$REPO/.claude/project-profile.yaml"; }

@test "minimal profile is ok" {
  run ns profile check "$FIX/minimal"
  assert_success
  [[ "$output" == ok:* ]]
}

@test "full profile is ok with the fixture agents" {
  run ns profile check "$FIX/full"
  assert_success
  [[ "$output" == ok:* ]]
}

@test "invalid YAML" {
  prof 'project: [unclosed'
  run ns profile check "$REPO"
  assert_failure 1
  assert_output_contains "project-profile.yaml: not valid YAML: "
}

@test "unknown top-level key" {
  prof "$(cat "$FIX/minimal/.claude/project-profile.yaml")
bogus: 1"
  run ns profile check "$REPO"
  assert_failure 1
  assert_output_contains "project-profile.yaml: \$: Additional properties are not allowed ('bogus' was unexpected)"
}

@test "missing docs file" {
  prof "$(cat "$FIX/minimal/.claude/project-profile.yaml")
docs: {contributing: CONTRIBUTING.md}"
  run ns profile check "$REPO"
  assert_failure 1
  [ "$output" = "docs.contributing: file not found: CONTRIBUTING.md" ]
}

@test "missing domain skill" {
  prof "$(cat "$FIX/minimal/.claude/project-profile.yaml")
domain_skills: [nope]"
  run ns profile check "$REPO"
  assert_failure 1
  [ "$output" = "domain_skills: skill not found: .claude/skills/nope/SKILL.md" ]
}

@test "missing workflow" {
  prof "$(cat "$FIX/minimal/.claude/project-profile.yaml")
ci: {workflows: {build.yml: {}}}"
  run ns profile check "$REPO"
  assert_failure 1
  [ "$output" = "ci.workflows: workflow not found: .github/workflows/build.yml" ]
}

@test "unknown stack" {
  prof "project: x
prefix: x
commands: {}
git: {}
stacks: [cobol]"
  run ns profile check "$REPO"
  assert_failure 1
  [ "$output" = "stacks: unknown stack: cobol" ]
}

@test "specialist not available" {
  prof "$(cat "$FIX/minimal/.claude/project-profile.yaml")
specialists: [database-expert]"
  run ns profile check "$REPO"
  assert_failure 1
  [ "$output" = "specialists: agent not available: database-expert" ]
}

@test "risk zone agent not available" {
  prof "$(cat "$FIX/minimal/.claude/project-profile.yaml")
risk_zones: {z: {paths: [a], require: [ghost]}}"
  run ns profile check "$REPO"
  assert_failure 1
  [ "$output" = "risk_zones.z.require: agent not available: ghost" ]
}

@test "show on minimal resolves defaults and stack checks" {
  run ns profile show "$FIX/minimal"
  assert_success
  [ "$(jq -r '.git.plan_branch' <<<"$output")" = "plan/{slug}" ]
  [ "$(jq -r '.budgets.T2.hours' <<<"$output")" = "8" ]
  [ "$(jq -c '.stacks[0].paths' <<<"$output")" = '["."]' ]
  [ "$(jq -r '.checks[] | select(.name=="lint") | .cmd' <<<"$output")" = ".venv/bin/python -m ruff check ." ]
  [ "$(jq -r '.checks[] | select(.name=="test") | .cmd' <<<"$output")" = ".venv/bin/python -m pytest -q" ]
}

@test "commands.test from the profile wins over the stack" {
  prof "project: x
prefix: x
commands: {test: 'true'}
git: {}
stacks: [python]"
  run ns profile show "$REPO"
  assert_success
  [ "$(jq -r '.checks[] | select(.name=="test") | .cmd' <<<"$output")" = "true" ]
}

@test "ns profile with an unknown subcommand is a usage error" {
  run ns profile bogus
  assert_failure 2
}

@test "ns_profile_json reads origin/main, not the working tree" {
  make_remote o/r "$FIX/minimal"
  git clone -q "$GH_STUB_REMOTES/o/r.git" "$BATS_TEST_TMPDIR/clone"
  git -C "$BATS_TEST_TMPDIR/clone" switch -q -c other
  rm -rf "$BATS_TEST_TMPDIR/clone/.claude"
  run ns_profile_json "$BATS_TEST_TMPDIR/clone" mn
  assert_success
  [ "$(jq -r .project <<<"$output")" = "minimal" ]
}

@test "ns_profile_json reads a given branch" {
  make_remote o/r "$FIX/minimal"
  git clone -q "$GH_STUB_REMOTES/o/r.git" "$BATS_TEST_TMPDIR/clone"
  git -C "$BATS_TEST_TMPDIR/clone" switch -q -c e2e/x
  sed -i 's/^project: minimal/project: onbranch/' "$BATS_TEST_TMPDIR/clone/.claude/project-profile.yaml"
  git -C "$BATS_TEST_TMPDIR/clone" commit -q -am branch
  git -C "$BATS_TEST_TMPDIR/clone" push -q origin e2e/x
  run ns_profile_json "$BATS_TEST_TMPDIR/clone" mn e2e/x
  assert_success
  [ "$(jq -r .project <<<"$output")" = "onbranch" ]
}

@test "ns_profile_json returns 3 with defaults when the ref has no profile" {
  make_remote o/r
  git clone -q "$GH_STUB_REMOTES/o/r.git" "$BATS_TEST_TMPDIR/clone"
  run ns_profile_json "$BATS_TEST_TMPDIR/clone" zz
  assert_failure 3
  [ "$(jq -r .git.base_branch <<<"$output")" = "main" ]
  [ "$(jq -r .prefix <<<"$output")" = "zz" ]
  [ "$(jq -c .checks <<<"$output")" = "[]" ]
}

@test "ns profile check on this repo is ok" {
  cd "$NS_REPO_ROOT"
  run ns profile check
  assert_success
  [[ "$output" == ok:* ]]
}

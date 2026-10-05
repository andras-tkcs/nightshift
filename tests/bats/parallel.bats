load helpers

setup() { ns_test_setup; }

@test "CI installs parallel and runs bats with --jobs" {
  run grep -E 'apt-get install.* parallel( |$)' "$NS_REPO_ROOT/.github/workflows/ci.yml"
  assert_success
  run grep -E 'bats --jobs ' "$NS_REPO_ROOT/.github/workflows/ci.yml"
  assert_success
}

@test "CLAUDE.md documents the parallel bats command and the parallel dependency" {
  run grep -F 'bats --jobs 2 tests/bats' "$NS_REPO_ROOT/CLAUDE.md"
  assert_success
  run grep -iE 'GNU parallel|`parallel`' "$NS_REPO_ROOT/CLAUDE.md"
  assert_success
}

@test "docs/development.md documents bats --jobs" {
  run grep -F 'bats --jobs' "$NS_REPO_ROOT/docs/development.md"
  assert_success
}

@test "bats tests do not match processes by name (parallel safety)" {
  run grep -nE '\b(pkill|killall)\b' "$NS_REPO_ROOT"/tests/bats/*.bats "$NS_REPO_ROOT"/tests/bats/helpers.bash --exclude=parallel.bats --exclude=e2e-harness.bats
  assert_failure
}

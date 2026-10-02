load helpers

setup() { ns_test_setup; }

fix() { echo "$NS_REPO_ROOT/tests/fixtures/docs-check/$1"; }

@test "good tree passes" {
  run "$NS_REPO_ROOT/tests/docs-check" --root "$(fix good)"
  assert_success
  [ "$output" = "docs-check: ok" ]
}

@test "bad tree reports undocumented command and broken link" {
  run "$NS_REPO_ROOT/tests/docs-check" --root "$(fix bad)"
  assert_failure 1
  assert_output_contains "docs/usage.md: ns bar is not documented"
  assert_output_contains "README.md:5: broken link docs/missing.md"
  [ "${lines[-1]}" = "docs-check: 2 problem(s)" ]
}

@test "--final reports missing spec 15 files" {
  run "$NS_REPO_ROOT/tests/docs-check" --final --root "$(fix good)"
  assert_failure 1
  assert_output_contains "docs/accounts.md: required by spec 15 but missing"
  assert_output_contains "CHANGELOG.md: required by spec 15 but missing"
  assert_output_not_contains "docs/stacks.md"
}

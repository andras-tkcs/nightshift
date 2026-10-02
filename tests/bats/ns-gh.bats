#!/usr/bin/env bats

load helpers

bats_require_minimum_version 1.5.0

setup() {
  ns_test_setup
  export GH_TOKEN=fake-admin
}

use_set() { export GH_STUB_RESPONSES="$NS_REPO_ROOT/tests/fixtures/gh-stub/responses/$1"; }

@test "--help prints the usage block and exits 0" {
  run ns-gh --help
  assert_success
  assert_output_contains "ns-gh audit owner/repo"
  run ns-gh -h
  assert_success
}

@test "bad arguments exit 2" {
  run ns-gh audit bad
  assert_failure 2
  run ns-gh audit "a/b/c"
  assert_failure 2
  run ns-gh audit acme/widget --nope
  assert_failure 2
  run ns-gh frob acme/widget
  assert_failure 2
}

@test "match: all settings match, exit 0" {
  use_set ns-gh-match
  run ns-gh audit acme/widget
  assert_success
  assert_output_contains "All settings match."
}

@test "diff audit: exactly four DIFF rows, exit 1, no writes" {
  use_set ns-gh-diff
  run ns-gh audit acme/widget
  assert_failure 1
  assert_output_contains "4 setting(s) differ."
  [ "$(grep -c ' DIFF$' <<<"$output")" -eq 4 ]
  for s in allow_rebase_merge dependabot_alerts ruleset_rules "label ns:done"; do
    grep -E "^$s +.* DIFF$" <<<"$output"
  done
  run grep -E 'api -X (PATCH|PUT|POST)|label create' "$GH_STUB_LOG"
  assert_failure 1
}

@test "diff apply --yes changes only what differs" {
  use_set ns-gh-diff
  run ns-gh apply acme/widget --yes
  assert_success
  assert_output_contains "Done."
  [ "$(grep -c '^gh api -X PATCH repos/acme/widget ' "$GH_STUB_LOG")" -eq 1 ]
  grep -q '^gh label create ns:done ' "$GH_STUB_LOG"
  grep -q '^gh api -X POST repos/acme/widget/rulesets ' "$GH_STUB_LOG"
  grep -q '^gh api -X PUT repos/acme/widget/vulnerability-alerts' "$GH_STUB_LOG"
  [ "$(grep -c 'api -X ' "$GH_STUB_LOG")" -eq 3 ]
  [ "$(grep -c '^gh label create' "$GH_STUB_LOG")" -eq 1 ]
}

@test "apply answering n changes nothing" {
  use_set ns-gh-diff
  run bash -c 'echo n | ns-gh apply acme/widget'
  assert_failure 1
  assert_output_contains "Nothing changed."
  run grep -E 'api -X |label create' "$GH_STUB_LOG"
  assert_failure 1
}

@test "apply accepts yes at the prompt" {
  use_set ns-gh-diff
  run bash -c 'echo yes | ns-gh apply acme/widget'
  assert_success
  assert_output_contains "Done."
}

@test "override file: unknown key and bad characters ignored, REQUIRED_CHECKS used" {
  use_set ns-gh-override
  run --separate-stderr ns-gh audit acme/widget
  [[ $stderr == *"ignoring unknown key BOGUS"* ]]
  [[ $stderr == *"ignoring ENVIRONMENTS: unexpected characters"* ]]
  grep -E '^required_checks +pytest ' <<<"$output"
}

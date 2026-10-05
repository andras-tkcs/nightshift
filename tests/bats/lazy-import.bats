#!/usr/bin/env bats
# ns-100: non-validating commands must not import jsonschema (~100 ms).

load helpers

setup() {
  ns_test_setup
  FIX="$NS_REPO_ROOT/tests/fixtures/profiles"
  LIB="$NS_REPO_ROOT/bin/lib"
}

# Run python with import timing; stderr (importtime output) goes to $output.
imports() {
  run bash -c 'python3 -X importtime "$@" 2>&1 >/dev/null' _ "$@"
}

@test "nsyaml to-json does not import jsonschema" {
  imports "$LIB/nsyaml.py" to-json "$FIX/minimal/.claude/project-profile.yaml"
  assert_output_not_contains "jsonschema"
}

@test "nsyaml from-json does not import jsonschema" {
  imports "$LIB/nsyaml.py" from-json "$BATS_TEST_TMPDIR/out.yaml" <<<'{"a": 1}'
  assert_output_not_contains "jsonschema"
}

@test "profile show does not import jsonschema" {
  imports "$LIB/profile.py" show "$FIX/minimal"
  assert_output_not_contains "jsonschema"
}

@test "profile defaults does not import jsonschema" {
  imports "$LIB/profile.py" defaults
  assert_output_not_contains "jsonschema"
}

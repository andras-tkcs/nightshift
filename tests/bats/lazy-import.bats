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
  [ "$status" -eq 0 ]
  assert_output_not_contains "jsonschema"
}

@test "nsyaml from-json does not import jsonschema" {
  imports "$LIB/nsyaml.py" from-json "$BATS_TEST_TMPDIR/out.yaml" <<<'{"a": 1}'
  [ "$status" -eq 0 ]
  assert_output_not_contains "jsonschema"
}

@test "profile show does not import jsonschema" {
  imports "$LIB/profile.py" show "$FIX/minimal/.claude/project-profile.yaml"
  [ "$status" -eq 0 ]
  assert_output_not_contains "jsonschema"
}

@test "profile defaults does not import jsonschema" {
  imports "$LIB/profile.py" defaults
  [ "$status" -eq 0 ]
  assert_output_not_contains "jsonschema"
}

@test "positive control: nsyaml validate does import jsonschema" {
  imports "$LIB/nsyaml.py" validate "$FIX/minimal/.claude/project-profile.yaml" "$NS_REPO_ROOT/schema/profile.schema.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"jsonschema"* ]]
}

@test "positive control: profile check does import jsonschema" {
  imports "$LIB/profile.py" check "$FIX/minimal/.claude/project-profile.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"jsonschema"* ]]
}

#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  SCHEMA="$NS_REPO_ROOT/schema/profile.schema.json"
  NSYAML="$NS_REPO_ROOT/bin/lib/nsyaml.py"
  GEN="$NS_REPO_ROOT/bin/lib/gen-profile-doc"
  SANDBOX="$NS_REPO_ROOT/templates/profiles/sandbox.yaml"
  PF="$NS_REPO_ROOT/templates/profiles/privacyfence.yaml"
}

validate() { python3 "$NSYAML" validate "$1" "$SCHEMA"; }

@test "every property in the schema has a description" {
  run python3 - "$SCHEMA" <<'EOF'
import json, sys
bad = []
def walk(node, path):
    if not isinstance(node, dict):
        return
    if path and "description" not in node:
        bad.append(path)
    for k, v in node.get("properties", {}).items():
        walk(v, f"{path}.{k}")
    for k, v in node.get("patternProperties", {}).items():
        walk(v, f"{path}.<{k}>")
    items = node.get("items")
    if items:
        walk(items, path + "[]")
    for i, alt in enumerate(node.get("anyOf", [])):
        walk(alt, f"{path}|{i}")
walk(json.load(open(sys.argv[1])), "")
print("\n".join(bad))
sys.exit(1 if bad else 0)
EOF
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "sandbox and privacyfence templates validate" {
  run validate "$SANDBOX"
  [ "$status" -eq 0 ]
  run validate "$PF"
  [ "$status" -eq 0 ]
}

@test "unknown top-level key fails" {
  cp "$SANDBOX" "$BATS_TEST_TMPDIR/p.yaml"
  echo "bogus: 1" >>"$BATS_TEST_TMPDIR/p.yaml"
  run validate "$BATS_TEST_TMPDIR/p.yaml"
  [ "$status" -eq 1 ]
}

@test "typo git.base_brnch fails" {
  sed 's/base_branch/base_brnch/' "$SANDBOX" >"$BATS_TEST_TMPDIR/p.yaml"
  run validate "$BATS_TEST_TMPDIR/p.yaml"
  [ "$status" -eq 1 ]
}

@test "missing stacks fails" {
  grep -v '^stacks:' "$SANDBOX" >"$BATS_TEST_TMPDIR/p.yaml"
  run validate "$BATS_TEST_TMPDIR/p.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" == *stacks* ]]
}

@test "prefix Bad fails" {
  sed 's/^prefix: sbx/prefix: Bad/' "$SANDBOX" >"$BATS_TEST_TMPDIR/p.yaml"
  run validate "$BATS_TEST_TMPDIR/p.yaml"
  [ "$status" -eq 1 ]
}

@test "ci.workflows with build.yml: {} passes" {
  cp "$SANDBOX" "$BATS_TEST_TMPDIR/p.yaml"
  printf 'ci:\n  workflows:\n    build.yml: {}\n' >>"$BATS_TEST_TMPDIR/p.yaml"
  run validate "$BATS_TEST_TMPDIR/p.yaml"
  [ "$status" -eq 0 ]
}

@test "risk zone with empty require passes" {
  cp "$SANDBOX" "$BATS_TEST_TMPDIR/p.yaml"
  printf 'risk_zones:\n  z: { paths: ["a/**"], require: [] }\n' >>"$BATS_TEST_TMPDIR/p.yaml"
  run validate "$BATS_TEST_TMPDIR/p.yaml"
  [ "$status" -eq 0 ]
}

@test "gen-profile-doc --check passes on the committed doc" {
  run "$GEN" --check
  [ "$status" -eq 0 ]
}

@test "gen-profile-doc --check fails on a modified copy" {
  cp "$NS_REPO_ROOT/docs/profile-reference.md" "$BATS_TEST_TMPDIR/ref.md"
  echo "extra" >>"$BATS_TEST_TMPDIR/ref.md"
  run "$GEN" --check --output "$BATS_TEST_TMPDIR/ref.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is stale: run bin/lib/gen-profile-doc"* ]]
}

@test "generated doc has the key rows" {
  "$GEN" --output "$BATS_TEST_TMPDIR/ref.md"
  grep -qF '| `git.base_branch` |' "$BATS_TEST_TMPDIR/ref.md"
  grep -qF '| `budgets.<tier>.hours` |' "$BATS_TEST_TMPDIR/ref.md"
  grep -qF '| `ci.workflows.<file>.input` |' "$BATS_TEST_TMPDIR/ref.md"
}

load helpers

setup() { ns_test_setup; }

fm() {
  awk -v k="$2" '
    NR==1 && $0!="---" {exit}
    NR>1 && $0=="---" {exit}
    NR>1 { i=index($0, ":"); if (i>0 && substr($0,1,i-1)==k) { v=substr($0,i+1); sub(/^[ \t]+/,"",v); print v; exit } }
  ' "$1"
}

@test "stack.yaml validates against the schema" {
  run "$NS_REPO_ROOT/bin/lib/nsyaml.py" validate "$NS_REPO_ROOT/plugins/ns-python/stack.yaml" "$NS_REPO_ROOT/schema/stack.schema.json"
  assert_success
}

@test "a stack.yaml with an extra key fails validation" {
  cp "$NS_REPO_ROOT/plugins/ns-python/stack.yaml" "$BATS_TEST_TMPDIR/stack.yaml"
  echo "bogus: 1" >>"$BATS_TEST_TMPDIR/stack.yaml"
  run "$NS_REPO_ROOT/bin/lib/nsyaml.py" validate "$BATS_TEST_TMPDIR/stack.yaml" "$NS_REPO_ROOT/schema/stack.schema.json"
  assert_failure
}

@test "each skill has matching name, description prefix and user-invocable false" {
  local f dir n=0
  for f in "$NS_REPO_ROOT"/plugins/ns-python/skills/*/SKILL.md; do
    n=$((n + 1))
    dir="$(basename "$(dirname "$f")")"
    [ "$(fm "$f" name)" = "$dir" ] || { echo "$f: name != $dir"; return 1; }
    case "$(fm "$f" description)" in
      "Use when editing Python files"*) ;;
      *) echo "$f: bad description"; return 1 ;;
    esac
    [ "$(fm "$f" user-invocable)" = "false" ] || { echo "$f: user-invocable"; return 1; }
  done
  [ "$n" -eq 3 ]
}

@test "every skills entry in stack.yaml has a directory" {
  local s n=0
  while IFS= read -r s; do
    n=$((n + 1))
    [ -f "$NS_REPO_ROOT/plugins/ns-python/skills/$s/SKILL.md" ] || { echo "missing $s"; return 1; }
  done < <("$NS_REPO_ROOT/bin/lib/nsyaml.py" to-json "$NS_REPO_ROOT/plugins/ns-python/stack.yaml" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["skills"]))')
  [ "$n" -gt 0 ]
}

@test "the python CI template parses" {
  run "$NS_REPO_ROOT/bin/lib/nsyaml.py" to-json "$NS_REPO_ROOT/templates/ci/python-tests.yml"
  assert_success
}

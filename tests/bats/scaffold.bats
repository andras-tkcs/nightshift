load helpers

setup() { ns_test_setup; }

@test "manifests are valid JSON with the right names" {
  run jq -re .name "$NS_REPO_ROOT/.claude-plugin/marketplace.json"
  assert_success
  [ "$output" = "nightshift" ]
  run jq -re .name "$NS_REPO_ROOT/plugins/ns/.claude-plugin/plugin.json"
  [ "$output" = "ns" ]
  run jq -re .name "$NS_REPO_ROOT/plugins/ns-python/.claude-plugin/plugin.json"
  [ "$output" = "ns-python" ]
}

@test "plugin manifests are version 0.1.0" {
  for p in ns ns-python; do
    run jq -re .version "$NS_REPO_ROOT/plugins/$p/.claude-plugin/plugin.json"
    assert_success
    [ "$output" = "0.1.0" ]
  done
}

@test "each marketplace source holds a plugin.json" {
  while IFS= read -r src; do
    [ -f "$NS_REPO_ROOT/$src/.claude-plugin/plugin.json" ]
  done < <(jq -r '.plugins[].source' "$NS_REPO_ROOT/.claude-plugin/marketplace.json")
}

@test "make_remote creates a bare repo with one commit on main" {
  make_remote acme/widget
  bare="$GH_STUB_REMOTES/acme/widget.git"
  [ -d "$bare" ]
  run git -C "$bare" rev-list --count main
  assert_success
  [ "$output" = "1" ]
}

@test "refute_token_in fails on a token and passes on a clean file" {
  tok="ghp_$(printf 'a%.0s' $(seq 1 36))"
  echo "x $tok" >"$BATS_TEST_TMPDIR/bad"
  echo "nothing here" >"$BATS_TEST_TMPDIR/good"
  run refute_token_in "$BATS_TEST_TMPDIR/bad"
  assert_failure
  run refute_token_in "$BATS_TEST_TMPDIR/good"
  assert_success
}

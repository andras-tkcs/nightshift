#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  # shellcheck source=/dev/null
  source "$NS_REPO_ROOT/bin/lib/common.sh"
  NSY="$NS_REPO_ROOT/bin/lib/nsyaml.py"
}

@test "ns_load_env exports values and strips quotes" {
  printf 'NS_A=1\nNS_B="two words"\n' >"$NS_CONFIG_DIR/env"
  unset NS_A NS_B
  ns_load_env
  [ "$NS_A" = 1 ]
  [ "$NS_B" = "two words" ]
}

@test "ns_load_env does not override a set variable" {
  printf 'NS_A=1\n' >"$NS_CONFIG_DIR/env"
  export NS_A=keep
  ns_load_env
  [ "$NS_A" = keep ]
}

@test "ns_load_env accepts export NS_ lines, unquotes, ignores PATH" {
  printf "PATH=/x\nexport PATH=/y\nexport NS_C=1\nexport  NS_E='q one'\nNS_F=\"q two\"\n" >"$NS_CONFIG_DIR/env"
  unset NS_C NS_E NS_F
  local before="$PATH"
  ns_load_env
  [ "$PATH" = "$before" ]
  [ "$NS_C" = 1 ]
  [ "$NS_E" = "q one" ]
  [ "$NS_F" = "q two" ]
}

@test "ns_load_env never executes command substitution" {
  printf 'NS_D=$(touch "%s/pwned")\n' "$BATS_TEST_TMPDIR" >"$NS_CONFIG_DIR/env"
  unset NS_D
  ns_load_env
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [ "$NS_D" = "\$(touch \"$BATS_TEST_TMPDIR/pwned\")" ]
}

@test "ns_now returns NS_NOW" {
  [ "$(ns_now)" = 2026-10-02T21:00:00Z ]
}

@test "ns_age gives s, m, h, d" {
  [ "$(ns_age 2026-10-02T20:59:15Z)" = 45s ]
  [ "$(ns_age 2026-10-02T20:48:00Z)" = 12m ]
  [ "$(ns_age 2026-10-02T18:00:00Z)" = 3h ]
  [ "$(ns_age 2026-09-30T20:00:00Z)" = 2d ]
}

@test "ns_has_token matches token shapes" {
  ns_has_token "github_pat_$(printf 'a%.0s' {1..22})"
  ns_has_token "ghs_$(printf 'b%.0s' {1..36})"
  ns_has_token "sk-$(printf 'c%.0s' {1..24})"
  run ns_has_token "ghp_short"
  [ "$status" -ne 0 ]
}

@test "ns_expand_path expands ~ and {coding}" {
  [ "$(ns_expand_path '~/x')" = "$HOME/x" ]
  [ "$(ns_expand_path '{coding}/w')" = "$NS_CODING_DIR/w" ]
}

@test "ns_plugin_args prints four lines for two dirs" {
  NS_PLUGIN_DIRS=/a:/b
  run ns_plugin_args
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[0]}" = --plugin-dir ]
  [ "${lines[1]}" = /a ]
  [ "${lines[3]}" = /b ]
}

@test "ns_die and ns_usage format and exit codes" {
  run ns_die "boom"
  [ "$status" -eq 1 ]
  [ "$output" = "ns: boom" ]
  NS_CMD="ns x" run ns_usage "ns x <a>"
  [ "$status" -eq 2 ]
  [ "$output" = "ns x: usage: ns x <a>" ]
}

@test "ns_require dies on a missing command" {
  run ns_require sh definitely-not-a-command
  [ "$status" -eq 1 ]
  [ "$output" = "ns: needs definitely-not-a-command" ]
}

@test "nsyaml round trip keeps key order" {
  printf '{"zeta":1,"alpha":[1,2],"mid":{"b":1,"a":2}}' | python3 "$NSY" from-json "$BATS_TEST_TMPDIR/o.yaml"
  run grep -n -E '^(zeta|alpha|mid):' "$BATS_TEST_TMPDIR/o.yaml"
  [ "${lines[0]%%:*}" -lt "${lines[1]%%:*}" ]
  [ "${lines[1]%%:*}" -lt "${lines[2]%%:*}" ]
  run python3 "$NSY" to-json "$BATS_TEST_TMPDIR/o.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '{"zeta": 1, "alpha": [1, 2], "mid": {"b": 1, "a": 2}}' ]
}

@test "ns_json_yaml writes from stdin" {
  echo '{"k":"v"}' | ns_json_yaml "$BATS_TEST_TMPDIR/j.yaml"
  [ "$(ns_yaml_json "$BATS_TEST_TMPDIR/j.yaml")" = '{"k": "v"}' ]
}

@test "from-json with invalid JSON exits 1 and keeps the target" {
  echo "keep: me" >"$BATS_TEST_TMPDIR/t.yaml"
  run bash -c "echo '{bad' | python3 '$NSY' from-json '$BATS_TEST_TMPDIR/t.yaml'"
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/t.yaml")" = "keep: me" ]
}

@test "validate prints errors and exits 1, silent 0 when valid" {
  cat >"$BATS_TEST_TMPDIR/s.json" <<'J'
{"type":"object","required":["n"],"properties":{"n":{"type":"integer"}}}
J
  echo 'n: x' >"$BATS_TEST_TMPDIR/bad.yaml"
  run python3 "$NSY" validate "$BATS_TEST_TMPDIR/bad.yaml" "$BATS_TEST_TMPDIR/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == "$BATS_TEST_TMPDIR/bad.yaml: \$.n: "* ]]
  echo '{"n": 3}' >"$BATS_TEST_TMPDIR/good.json"
  run python3 "$NSY" validate "$BATS_TEST_TMPDIR/good.json" "$BATS_TEST_TMPDIR/s.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "to-json on broken YAML exits 1 with nsyaml: <file>:" {
  echo 'a: [' >"$BATS_TEST_TMPDIR/b.yaml"
  run python3 "$NSY" to-json "$BATS_TEST_TMPDIR/b.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" == "nsyaml: $BATS_TEST_TMPDIR/b.yaml:"* ]]
}

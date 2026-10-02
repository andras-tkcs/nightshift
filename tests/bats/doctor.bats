#!/usr/bin/env bats

load helpers

TOKEN=ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

setup() {
  ns_test_setup
  export GH_STUB_RESPONSES="$NS_REPO_ROOT/tests/fixtures/gh-stub/responses/doctor/ok"
  export NS_REBOOT_FILE="$BATS_TEST_TMPDIR/no-reboot"
  mkdir -p "$NS_CONFIG_DIR/tokens"
  printf '%s\n' "$TOKEN" >"$NS_CONFIG_DIR/tokens/andras-tkcs"
  chmod 600 "$NS_CONFIG_DIR/tokens/andras-tkcs"
  export NS_NTFY_TOPIC=ns-test
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

@test "all green with stubs exits 0 and has no FAIL" {
  run ns doctor
  assert_success
  assert_output_not_contains "FAIL"
  assert_output_contains "ok   token andras-tkcs"
  assert_output_contains "ok   service caddy"
  assert_output_contains "ok   auto-mode"
}

@test "an inactive caddy is a FAIL and exit 1" {
  SYSTEMCTL_STUB_INACTIVE=caddy run ns doctor
  assert_failure 1
  assert_output_contains "FAIL service caddy"
  assert_output_contains "ok   service cloudflared"
}

@test "a token file with mode 644 is a FAIL" {
  chmod 644 "$NS_CONFIG_DIR/tokens/andras-tkcs"
  run ns doctor
  assert_failure 1
  assert_output_contains "FAIL token andras-tkcs: mode is 644"
}

@test "a token expiring in 5 days is a warning" {
  export GH_STUB_RESPONSES="$NS_REPO_ROOT/tests/fixtures/gh-stub/responses/doctor/soon"
  run ns doctor
  assert_success
  assert_output_contains "warn token andras-tkcs: expires in 5 days"
}

@test "an expired token is a FAIL" {
  export GH_STUB_RESPONSES="$NS_REPO_ROOT/tests/fixtures/gh-stub/responses/doctor/past"
  run ns doctor
  assert_failure 1
  assert_output_contains "FAIL token andras-tkcs: expired"
}

@test "the token value never appears in the output or the logs" {
  run ns doctor
  assert_success
  assert_output_not_contains "$TOKEN"
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/out.txt"
  refute_token_in "$BATS_TEST_TMPDIR/out.txt" "$GH_STUB_LOG" "$NS_STUB_LOG"
}

@test "a missing desk directory is a FAIL" {
  rmdir "$NS_DESK_DIR"
  run ns doctor
  assert_failure 1
  assert_output_contains "FAIL desk"
}

@test "an HTTP 502 from the desk URL is a FAIL" {
  NS_DESK_URL=https://desk.example.invalid CURL_STUB_HTTP_CODE=502 run ns doctor
  assert_failure 1
  assert_output_contains "FAIL desk-url: HTTP 502"
}

@test "an HTTP 200 from the desk URL is ok" {
  NS_DESK_URL=https://desk.example.invalid run ns doctor
  assert_success
  assert_output_contains "ok   desk-url: HTTP 200"
}

@test "a failing auto mode is a FAIL with the R-CON-4 hint" {
  CLAUDE_STUB_MODE=fail run ns doctor
  assert_failure 1
  assert_output_contains "FAIL auto-mode"
  assert_output_contains "NS_WORKER_MODE=bypassPermissions"
  assert_output_contains "docs/security.md"
}

@test "--no-claude skips the auto mode check with a warning" {
  CLAUDE_STUB_MODE=fail run ns doctor --no-claude
  assert_success
  assert_output_contains "warn auto-mode: skipped"
}

@test "a running run without a session is a warning naming ns resume" {
  local fix="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$fix/.claude"
  cat >"$fix/.claude/project-profile.yaml" <<'EOF'
project: nightshift-sandbox
prefix: sbx
commands:
  setup: "true"
git: {}
stacks: [python]
EOF
  printf '# sandbox\n' >"$fix/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$fix"
  ns project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  ns new sbx-12 --tier T1 --yes >/dev/null
  local ledger="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12/.nightshift/runs/sbx-12/ledger.yaml"
  ns-ledger set "$ledger" '.state="running"'
  rm -f "$TMUX_STUB_DIR/sbx-12"
  run ns doctor
  assert_success
  assert_output_contains "warn runs: run sbx-12 has no session: ns resume sbx-12"
}

@test "ns doctor reads export lines from the env file" {
  unset NS_NTFY_TOPIC
  printf "export NS_NTFY_TOPIC='ns-from-file'\n" >"$NS_CONFIG_DIR/env"
  run ns doctor
  assert_output_not_contains "NS_NTFY_TOPIC: not set"
  assert_output_contains "ok   NS_NTFY_TOPIC"
}

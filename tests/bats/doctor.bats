#!/usr/bin/env bats

load helpers

TOKEN=ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
NTFY_TOKEN=tk_abcdefghijklmnopqrstuvwxyz012

setup() {
  ns_test_setup
  export GH_STUB_RESPONSES="$NS_REPO_ROOT/tests/fixtures/gh-stub/responses/doctor/ok"
  export NS_REBOOT_FILE="$BATS_TEST_TMPDIR/no-reboot"
  mkdir -p "$NS_CONFIG_DIR/tokens"
  printf '%s\n' "$TOKEN" >"$NS_CONFIG_DIR/tokens/andras-tkcs"
  chmod 600 "$NS_CONFIG_DIR/tokens/andras-tkcs"
  # tokens/<owner> is only a GitHub token when <owner> owns a registered project (#33)
  mkdir -p "$BATS_TEST_TMPDIR/doc-fixture"
  cat >"$NS_CONFIG_DIR/projects.yaml" <<EOF
projects:
  - name: doc-fixture
    repo: andras-tkcs/doc-fixture
    prefix: dfx
    path: $BATS_TEST_TMPDIR/doc-fixture
EOF
  export NS_NTFY_TOPIC=ns-test
}

# ntfy_token [mode] [token]: writes an ntfy token (valid by default) to tokens/ntfy
ntfy_token() {
  printf '%s\n' "${2:-$NTFY_TOKEN}" >"$NS_CONFIG_DIR/tokens/ntfy"
  chmod "${1:-600}" "$NS_CONFIG_DIR/tokens/ntfy"
}

# gh_spy: puts a gh in front of the stub that records a call made with the ntfy token
gh_spy() {
  mkdir -p "$BATS_TEST_TMPDIR/spy"
  cat >"$BATS_TEST_TMPDIR/spy/gh" <<EOF
#!/usr/bin/env bash
[ "\${GH_TOKEN:-}" != "$NTFY_TOKEN" ] || echo seen >>"$BATS_TEST_TMPDIR/ntfy-at-gh"
exec "$NS_REPO_ROOT/tests/fixtures/gh-stub/gh" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/spy/gh"
  export PATH="$BATS_TEST_TMPDIR/spy:$PATH"
}

user_calls() { grep -c '^gh api -i user' "$GH_STUB_LOG" || true; }

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

@test "tokens/ntfy never reaches gh; only the registered owner's token does (#33)" {
  gh_spy
  ntfy_token
  NS_NTFY_URL=https://ntfy.example:8444 run ns doctor
  assert_success
  [ ! -e "$BATS_TEST_TMPDIR/ntfy-at-gh" ]
  [ "$(user_calls)" = 1 ]
  assert_output_contains "ok   token andras-tkcs"
  assert_output_contains "ok   token ntfy: mode 600, test publish to https://ntfy.example:8444 ok"
  assert_output_not_contains "$NTFY_TOKEN"
}

@test "a token file not named after a registered project owner is not sent to gh (#33)" {
  gh_spy
  printf '%s\n' "$NTFY_TOKEN" >"$NS_CONFIG_DIR/tokens/someone-else"
  chmod 600 "$NS_CONFIG_DIR/tokens/someone-else"
  run ns doctor
  assert_success
  [ ! -e "$BATS_TEST_TMPDIR/ntfy-at-gh" ]
  [ "$(user_calls)" = 1 ]
  assert_output_contains "warn token someone-else: not named after a registered project owner, not checked"
}

@test "an owner token file without a registered project is not sent to gh (#33)" {
  rm "$NS_CONFIG_DIR/projects.yaml"
  run ns doctor
  [ "$(user_calls)" = 0 ]
  assert_output_contains "warn token andras-tkcs: not named after a registered project owner, not checked"
}

@test "a token file with mode 644 is a FAIL even when not a registered owner (#33)" {
  printf 'x\n' >"$NS_CONFIG_DIR/tokens/someone-else"
  chmod 644 "$NS_CONFIG_DIR/tokens/someone-else"
  run ns doctor
  assert_failure 1
  assert_output_contains "FAIL token someone-else: mode is 644, must be 600"
}

@test "a tokens/ntfy with mode 644 is a FAIL and nothing is published (#33)" {
  ntfy_token 644
  run ns doctor
  assert_failure 1
  assert_output_contains "FAIL token ntfy: mode is 644, must be 600"
  ! grep -q '^curl' "$NS_STUB_LOG"
}

@test "a tokens/ntfy not in ntfy's format is a FAIL (#33)" {
  ntfy_token 600 'tk_short"quote'
  run ns doctor
  assert_failure 1
  assert_output_contains "FAIL token ntfy: not an ntfy token"
  ! grep -q '^curl' "$NS_STUB_LOG"
}

@test "the ntfy test publish goes to NS_NTFY_URL with the token on stdin (#33)" {
  ntfy_token
  NS_NTFY_URL=https://ntfy.example:8444 run ns doctor
  assert_success
  assert_output_contains "ok   token ntfy: mode 600, test publish to https://ntfy.example:8444 ok"
  grep -qF 'https://ntfy.example:8444/ns-test' "$NS_STUB_LOG"
  grep -qF "curl-stdin header = \"Authorization: Bearer $NTFY_TOKEN\"" "$NS_STUB_LOG"
  ! grep '^curl ' "$NS_STUB_LOG" | grep -qF "$NTFY_TOKEN"
}

@test "a refused ntfy test publish is a FAIL (#33)" {
  ntfy_token
  NS_NTFY_URL=https://ntfy.example:8444 CURL_STUB_HTTP_CODE=403 run ns doctor
  assert_failure 1
  assert_output_contains "FAIL token ntfy: test publish failed: ns-notify: ntfy answered HTTP 403; not sent"
}

@test "without NS_NTFY_TOPIC the ntfy test publish is skipped with a warning (#33)" {
  unset NS_NTFY_TOPIC
  ntfy_token
  run ns doctor
  assert_output_contains "warn token ntfy: mode 600, test publish skipped (NS_NTFY_TOPIC not set)"
  ! grep -q '^curl' "$NS_STUB_LOG"
}

@test "a token file name with a newline never matches an owner (review 2)" {
  gh_spy
  local f="$NS_CONFIG_DIR/tokens/andras-tkcs"$'\n'zzz
  printf '%s\n' "$NTFY_TOKEN" >"$f"
  chmod 600 "$f"
  run ns doctor
  [ ! -e "$BATS_TEST_TMPDIR/ntfy-at-gh" ]
  [ "$(user_calls)" = 1 ]
  assert_output_contains "not named after a registered project owner, not checked"
}

@test "with NS_NTFY_URL unset or ntfy.sh the test publish is skipped with a warning (review 4)" {
  ntfy_token
  for u in "" https://ntfy.sh; do
    : >"$NS_STUB_LOG"
    NS_NTFY_URL=$u run ns doctor
    assert_success
    assert_output_contains "warn token ntfy: mode 600, test publish skipped (NS_NTFY_URL is not set or points at ntfy.sh; the token is only sent to your own ntfy, see R-NOT-5)"
    ! grep -q '^curl' "$NS_STUB_LOG"
  done
}

@test "an owner token file holding an ntfy token is a FAIL and never sent (review 5)" {
  gh_spy
  printf '%s\n' "$NTFY_TOKEN" >"$NS_CONFIG_DIR/tokens/andras-tkcs"
  run ns doctor
  assert_failure 1
  assert_output_contains "FAIL token andras-tkcs: holds an ntfy token, not sent to GitHub"
  [ ! -e "$BATS_TEST_TMPDIR/ntfy-at-gh" ]
  [ "$(user_calls)" = 0 ]
}

@test "the doctor test publish has priority min (review 6)" {
  ntfy_token
  NS_NTFY_URL=https://ntfy.example:8444 run ns doctor
  assert_success
  grep -qF -- '-H Priority: min' "$NS_STUB_LOG"
}

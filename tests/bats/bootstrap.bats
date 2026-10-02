#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  export PATH="$NS_REPO_ROOT/tests/fixtures/bootstrap/bin:$PATH"
  export NS_BS_ROOT="$BATS_TEST_TMPDIR/root"
  export NS_USER=bsuser
  export NS_USER_HOME="$NS_BS_ROOT/home/bsuser"
  export NS_BS_TEMPLATES="$NS_REPO_ROOT/templates"
  mkdir -p "$NS_BS_ROOT"
}

bootstrap() { "$NS_REPO_ROOT/bin/bootstrap.sh" "$@"; }

snapshot() {
  (
    cd "$NS_BS_ROOT"
    find . | sort
    find . -type f -exec sha256sum {} + | sort
  )
}

# A tree on which steps 1 to 5 are all ok.
prepare_tree() {
  local r="$NS_BS_ROOT" h="$NS_USER_HOME"
  mkdir -p "$r/etc/caddy" "$r/etc/default" "$r/srv/ns-space" "$r/etc/systemd/system" \
    "$r/etc/ssh" "$h/opt/silverbullet" "$h/sb-data" \
    "$h/.config/systemd/user/default.target.wants"
  sed 's/@TS_HOST@/ns-main.example.ts.net/g' "$NS_REPO_ROOT/templates/caddy/Caddyfile.tmpl" \
    >"$r/etc/caddy/Caddyfile"
  echo 'TS_PERMIT_CERT_UID=caddy' >"$r/etc/default/tailscaled"
  printf '#!/bin/sh\n' >"$h/opt/silverbullet/silverbullet"
  chmod +x "$h/opt/silverbullet/silverbullet"
  cp "$NS_REPO_ROOT/templates/systemd/silverbullet.service" "$h/.config/systemd/user/"
  ln -s ../silverbullet.service "$h/.config/systemd/user/default.target.wants/silverbullet.service"
  : >"$r/etc/systemd/system/cloudflared.service"
  echo 'ssh-ed25519 AAAA test' >"$r/etc/ssh/cloudflare_ca.pub"
}

@test "--check on an empty tree reports each step and changes nothing" {
  before="$(snapshot)"
  run bootstrap --check
  assert_failure 1
  [ "$(printf '%s\n' "$output" | grep -c '^\[[0-9]*/11\]')" -eq 5 ]
  assert_output_contains "[1/11]"
  assert_output_contains "[5/11]"
  printf '%s\n' "$output" | grep -E '^\[1/11\].*would change'
  printf '%s\n' "$output" | grep -E '^\[2/11\].*would change'
  printf '%s\n' "$output" | grep -E '^\[3/11\].*would change'
  printf '%s\n' "$output" | grep -E '^\[4/11\].*needs you: tunnel token'
  printf '%s\n' "$output" | grep -E '^\[5/11\].*ok \(not configured\)'
  after="$(snapshot)"
  [ "$before" = "$after" ]
}

@test "--check on a prepared tree prints five ok lines and exits 0" {
  prepare_tree
  run bootstrap --check
  assert_success
  [ "$(printf '%s\n' "$output" | grep -c '^\[[0-9]*/11\].*: ok')" -eq 5 ]
  assert_output_not_contains "would change"
  assert_output_not_contains "needs you"
}

@test "--check with a changed Caddyfile says would change for step 1" {
  prepare_tree
  echo '# edited' >>"$NS_BS_ROOT/etc/caddy/Caddyfile"
  run bootstrap --check
  assert_failure 1
  printf '%s\n' "$output" | grep -E '^\[1/11\].*would change: update /etc/caddy/Caddyfile'
}

@test "without --check as non-root exits 2" {
  run bootstrap
  assert_failure 2
  assert_output_contains "run as root, or use --check"
  [ -z "$(find "$NS_BS_ROOT" -mindepth 1)" ]
}

@test "--upgrade is not available yet and exits 2" {
  run bootstrap --upgrade v0.1.0
  assert_failure 2
  assert_output_contains "not available yet"
}

@test "--help exits 0" {
  run bootstrap --help
  assert_success
  assert_output_contains "--check"
}

@test "no output line looks like a token" {
  run bootstrap --check
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/out.txt"
  refute_token_in "$BATS_TEST_TMPDIR/out.txt" "$NS_STUB_LOG"
}

@test "the rendered Caddyfile has the desk, the HTML listener and the tunnel listener" {
  out="$BATS_TEST_TMPDIR/Caddyfile"
  sed "s/@TS_HOST@/$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')/g" \
    "$NS_REPO_ROOT/templates/caddy/Caddyfile.tmpl" >"$out"
  grep -q 'ns-main.example.ts.net:8443' "$out"
  grep -q 'http://127.0.0.1:8080' "$out"
  grep -q 'reverse_proxy 127.0.0.1:3000' "$out"
  [ "$(grep -c 'get_certificate tailscale' "$out")" -eq 2 ]
  ! grep -q '@TS_HOST@' "$out"
}

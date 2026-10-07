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
  make_release_remote
}

bootstrap() { "$NS_REPO_ROOT/bin/bootstrap.sh" "$@"; }

# Apply path as the test user: the root rule is bypassed and runuser runs its command.
bootstrap_apply() {
  NS_BS_TEST=1 RUNUSER_STUB_EXEC=1 "$NS_REPO_ROOT/bin/bootstrap.sh" "$@"
}

snapshot() {
  (
    cd "$NS_BS_ROOT"
    find . | sort
    find . -type f -exec sha256sum {} + | sort
  )
}

# A bare repo andras-tkcs/nightshift with the six executables and the tags v0.0.9 and v0.1.0.
make_release_remote() {
  local fx="$BATS_TEST_TMPDIR/fx" n work
  mkdir -p "$fx/bin"
  for n in ns ns-conductor ns-notify ns-gh ns-ledger ns-launch; do
    printf '#!/bin/sh\n' >"$fx/bin/$n"
    chmod +x "$fx/bin/$n"
  done
  make_remote andras-tkcs/nightshift "$fx"
  export NS_REPO_URL="$GH_STUB_REMOTES/andras-tkcs/nightshift.git"
  work="$BATS_TEST_TMPDIR/tagwork"
  git clone -q "$NS_REPO_URL" "$work"
  git -C "$work" tag v0.0.9
  echo more >"$work/more.txt"
  git -C "$work" add more.txt
  git -C "$work" commit -q -m more
  git -C "$work" tag v0.1.0
  git -C "$work" push -q origin --tags
}

# A tree on which all eleven steps are ok.
prepare_tree() {
  local r="$NS_BS_ROOT" h="$NS_USER_HOME"
  mkdir -p "$r/etc/caddy" "$r/etc/default" "$r/srv/ns-space" "$r/etc/systemd/system" \
    "$r/etc/ssh" "$r/var/lib/systemd/linger" "$h/opt/silverbullet" "$h/sb-data" \
    "$h/.config/systemd/user/default.target.wants" "$h/.config/systemd/user/timers.target.wants" \
    "$h/.config/hcloud" "$h/.config/ns" "$h/.local/bin"
  sed 's/@TS_HOST@/ns-main.example.ts.net/g' "$NS_REPO_ROOT/templates/caddy/Caddyfile.tmpl" \
    >"$r/etc/caddy/Caddyfile"
  echo 'TS_PERMIT_CERT_UID=caddy' >"$r/etc/default/tailscaled"
  printf '#!/bin/sh\n' >"$h/opt/silverbullet/silverbullet"
  chmod +x "$h/opt/silverbullet/silverbullet"
  cp "$NS_REPO_ROOT/templates/systemd/silverbullet.service" "$h/.config/systemd/user/"
  ln -s ../silverbullet.service "$h/.config/systemd/user/default.target.wants/silverbullet.service"
  : >"$r/var/lib/systemd/linger/$NS_USER"
  : >"$r/etc/systemd/system/cloudflared.service"
  echo 'ssh-ed25519 AAAA test' >"$r/etc/ssh/cloudflare_ca.pub"
  printf '#!/bin/sh\n' >"$h/.local/bin/hcloud"
  chmod +x "$h/.local/bin/hcloud"
  printf '[[contexts]]\n  name = "nightshift-lab"\n' >"$h/.config/hcloud/cli.toml"
  printf "export NS_NTFY_TOPIC='ns-deadbeefdeadbeef'\nexport NS_DESK_URL='https://desk.example.com'\n" \
    >"$h/.config/ns/env"
  chmod 600 "$h/.config/ns/env"
  cp "$NS_REPO_ROOT"/templates/systemd/ns-gc.* "$h/.config/systemd/user/"
  ln -s ../ns-gc.timer "$h/.config/systemd/user/timers.target.wants/ns-gc.timer"
  cp "$NS_REPO_ROOT"/templates/systemd/ns-health.* "$h/.config/systemd/user/"
  ln -s ../ns-health.timer "$h/.config/systemd/user/timers.target.wants/ns-health.timer"
  run bootstrap_apply --upgrade v0.1.0
  [ "$status" -eq 0 ]
}

@test "--check on an empty tree reports each step and changes nothing" {
  before="$(snapshot)"
  run bootstrap --check
  assert_failure 1
  [ "$(printf '%s\n' "$output" | grep -c '^\[[0-9]*/11\]')" -eq 11 ]
  for n in 1 2 3 6 7 8 9 10 11; do
    printf '%s\n' "$output" | grep -E "^\[$n/11\].*would change"
  done
  printf '%s\n' "$output" | grep -E '^\[4/11\].*needs you: tunnel token'
  printf '%s\n' "$output" | grep -E '^\[5/11\].*ok \(not configured\)'
  after="$(snapshot)"
  [ "$before" = "$after" ]
}

@test "--check on a prepared tree prints eleven ok lines and exits 0" {
  prepare_tree
  run bootstrap --check
  assert_success
  [ "$(printf '%s\n' "$output" | grep -c '^\[[0-9]*/11\].*: ok')" -eq 11 ]
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

@test "--check after a newer tag appears says would change for step 8" {
  prepare_tree
  work="$BATS_TEST_TMPDIR/tagwork"
  git -C "$work" tag v0.2.0
  git -C "$work" push -q origin --tags
  run bootstrap --check
  assert_failure 1
  printf '%s\n' "$output" | grep -E '^\[8/11\].*would change: install release v0.2.0'
}

@test "step 8 with no release tag needs you" {
  make_remote andras-tkcs/untagged
  export NS_REPO_URL="$GH_STUB_REMOTES/andras-tkcs/untagged.git"
  run bootstrap --check
  assert_failure 1
  printf '%s\n' "$output" | grep -E '^\[8/11\].*needs you: no release tag yet'
}

@test "step 8 and 9 apply install the newest release, the links and the pinned plugins" {
  NS_BS_STEPS="8 9" run bootstrap_apply
  assert_success
  [ -d "$NS_BS_ROOT/opt/nightshift/v0.1.0/bin" ]
  [ "$(readlink "$NS_BS_ROOT/opt/nightshift/current")" = v0.1.0 ]
  [ -z "$(find "$NS_BS_ROOT/opt/nightshift/v0.1.0" -perm /022)" ]
  for n in ns ns-conductor ns-notify ns-gh ns-ledger ns-launch; do
    [ "$(readlink "$NS_BS_ROOT/usr/local/bin/$n")" = "/opt/nightshift/current/bin/$n" ]
    [ -e "$NS_BS_ROOT/opt/nightshift/current/bin/$n" ]
  done
  grep -F 'claude plugin marketplace add andras-tkcs/nightshift#v0.1.0' "$NS_STUB_LOG"
  grep -F 'claude plugin install ns@nightshift --scope user' "$NS_STUB_LOG"
  grep -F 'claude plugin install ns-python@nightshift --scope user' "$NS_STUB_LOG"
  NS_BS_STEPS="8 9" run bootstrap --check
  assert_success
}

@test "--upgrade to an older tag repoints current, keeps the newer one and re-pins" {
  run bootstrap_apply --upgrade v0.1.0
  assert_success
  : >"$NS_STUB_LOG"
  run bootstrap_apply --upgrade v0.0.9
  assert_success
  [ "$(readlink "$NS_BS_ROOT/opt/nightshift/current")" = v0.0.9 ]
  [ -d "$NS_BS_ROOT/opt/nightshift/v0.1.0" ]
  [ -d "$NS_BS_ROOT/opt/nightshift/v0.0.9" ]
  grep -F 'claude plugin marketplace remove nightshift' "$NS_STUB_LOG"
  grep -F 'claude plugin marketplace add andras-tkcs/nightshift#v0.0.9' "$NS_STUB_LOG"
  [ "$(cat "$NS_USER_HOME/.config/ns/release-pin")" = "andras-tkcs/nightshift#v0.0.9" ]
}

@test "--upgrade to an unknown tag exits 1 and changes nothing" {
  before="$(snapshot)"
  run bootstrap_apply --upgrade v9.9.9
  assert_failure 1
  assert_output_contains "v9.9.9 not found"
  [ "$before" = "$(snapshot)" ]
}

@test "--upgrade without a tag exits 2" {
  run bootstrap --upgrade
  assert_failure 2
}

@test "--upgrade as non-root without the test switch exits 2" {
  run bootstrap --upgrade v0.1.0
  assert_failure 2
  assert_output_contains "run as root, or use --check"
}

@test "step 3 apply enables lingering for the service user" {
  NS_BS_STEPS=3 run bootstrap_apply
  grep -F "loginctl enable-linger $NS_USER" "$NS_STUB_LOG"
}

@test "step 6 passes the hcloud token by environment only" {
  local tok="ghp_$(printf 'a%.0s' {1..30})"
  mkdir -p "$NS_USER_HOME/.local/bin"
  cat >"$NS_USER_HOME/.local/bin/hcloud" <<EOF
#!/bin/sh
echo "hcloud \$* token=\${HCLOUD_TOKEN:+set}" >>"$NS_STUB_LOG"
mkdir -p "$NS_USER_HOME/.config/hcloud"
printf '[[contexts]]\n  name = "nightshift-lab"\n' >"$NS_USER_HOME/.config/hcloud/cli.toml"
EOF
  chmod +x "$NS_USER_HOME/.local/bin/hcloud"
  NS_BS_STEPS=6 run bootstrap_apply <<<"$tok"
  assert_success
  printf '%s\n' "$output" | grep -E '^\[6/11\].*changed'
  grep -F 'hcloud context create --token-from-env nightshift-lab token=set' "$NS_STUB_LOG"
  ! grep -F "$tok" "$NS_STUB_LOG"
  ! printf '%s' "$output" | grep -F "$tok"
  NS_BS_STEPS=6 run bootstrap --check
  assert_success
}

@test "step 7 writes the env file with mode 600 and prints the topic" {
  NS_BS_STEPS=7 run bootstrap_apply <<<"https://desk.example.com"
  assert_success
  assert_output_contains "ns-deadbeefdeadbeef"
  f="$NS_USER_HOME/.config/ns/env"
  [ "$(stat -c %a "$f")" = 600 ]
  grep -qx "export NS_NTFY_TOPIC='ns-deadbeefdeadbeef'" "$f"
  grep -qx "export NS_DESK_URL='https://desk.example.com'" "$f"
  NS_BS_STEPS=7 run bootstrap --check
  assert_success
}

@test "step 10 installs the ns-gc units" {
  NS_BS_STEPS=10 run bootstrap_apply
  assert_success
  cmp "$NS_REPO_ROOT/templates/systemd/ns-gc.timer" "$NS_USER_HOME/.config/systemd/user/ns-gc.timer"
  grep -F 'systemctl --user enable --now ns-gc.timer' "$NS_STUB_LOG"
  cmp "$NS_REPO_ROOT/templates/systemd/ns-health.timer" "$NS_USER_HOME/.config/systemd/user/ns-health.timer"
  grep -F "systemctl --user enable --now ns-health.timer" "$NS_STUB_LOG"
  assert_output_contains "no project yet"
}

@test "without --check as non-root exits 2" {
  run bootstrap
  assert_failure 2
  assert_output_contains "run as root, or use --check"
  [ -z "$(find "$NS_BS_ROOT" -mindepth 1)" ]
}

@test "--help exits 0" {
  run bootstrap --help
  assert_success
  assert_output_contains "--check"
  assert_output_contains "--upgrade"
}

@test "no output line or stub log line looks like a token" {
  run bootstrap --check
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/out.txt"
  run bootstrap_apply --upgrade v0.1.0
  printf '%s\n' "$output" >>"$BATS_TEST_TMPDIR/out.txt"
  refute_token_in "$BATS_TEST_TMPDIR/out.txt" "$NS_STUB_LOG"
}

@test "the rendered Caddyfile has the desk, the HTML listener and the tunnel listener" {
  out="$BATS_TEST_TMPDIR/Caddyfile"
  sed "s/@TS_HOST@/$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')/g" \
    "$NS_REPO_ROOT/templates/caddy/Caddyfile.tmpl" >"$out"
  grep -q 'ns-main.example.ts.net:8443' "$out"
  grep -q 'ns-main.example.ts.net:8444' "$out"
  grep -q 'reverse_proxy 127.0.0.1:2586' "$out"
  grep -q 'http://127.0.0.1:8080' "$out"
  grep -q 'reverse_proxy 127.0.0.1:3000' "$out"
  [ "$(grep -c 'get_certificate tailscale' "$out")" -eq 3 ]
  ! grep -q '@TS_HOST@' "$out"
}

# A git wrapper whose clone fails, as on a network or disk-full error.
git_clone_fails() {
  mkdir -p "$BATS_TEST_TMPDIR/gitfail"
  printf '#!/bin/sh\ncase "$1" in clone) exit 128 ;; esac\nexec %s "$@"\n' "$(command -v git)" \
    >"$BATS_TEST_TMPDIR/gitfail/git"
  chmod +x "$BATS_TEST_TMPDIR/gitfail/git"
  export PATH="$BATS_TEST_TMPDIR/gitfail:$PATH"
}

@test "--upgrade clone failure needs you, keeps current and the links" {
  run bootstrap_apply --upgrade v0.1.0
  assert_success
  git_clone_fails
  run bootstrap_apply --upgrade v0.0.9
  assert_failure 1
  printf '%s\n' "$output" | grep -E '^\[8/11\].*needs you: clone of v0.0.9 failed'
  ! printf '%s\n' "$output" | grep -E 'changed'
  [ "$(readlink "$NS_BS_ROOT/opt/nightshift/current")" = v0.1.0 ]
  [ ! -e "$NS_BS_ROOT/opt/nightshift/v0.0.9" ]
  [ -z "$(find "$NS_BS_ROOT/opt/nightshift" -name '.clone-*')" ]
  [ "$(readlink "$NS_BS_ROOT/usr/local/bin/ns")" = /opt/nightshift/current/bin/ns ]
}

@test "--upgrade clone failure with no current creates no current" {
  git_clone_fails
  run bootstrap_apply --upgrade v0.1.0
  assert_failure 1
  printf '%s\n' "$output" | grep -E '^\[8/11\].*needs you: clone of v0.1.0 failed'
  [ ! -L "$NS_BS_ROOT/opt/nightshift/current" ]
  [ ! -L "$NS_BS_ROOT/usr/local/bin/ns" ]
}

@test "step 1 with a failing apt-get does not report changed and exits non-zero" {
  mkdir -p "$BATS_TEST_TMPDIR/nocaddy"
  # The host may have a real caddy or tmux (a live run's session would block the step): build a
  # PATH of every other tool but caddy, with the stubs (incl. the tmux stub) linked last so they win.
  # two batched ln calls (one fork each), not one per tool; the stubs are linked last and win
  find /usr/bin -mindepth 1 -maxdepth 1 ! -name caddy -exec ln -sf -t "$BATS_TEST_TMPDIR/nocaddy" {} +
  ln -sf -t "$BATS_TEST_TMPDIR/nocaddy" "$NS_REPO_ROOT"/tests/fixtures/bin/*
  ln -sf -t "$BATS_TEST_TMPDIR/nocaddy" "$NS_REPO_ROOT"/tests/fixtures/bootstrap/bin/*
  rm -f "$BATS_TEST_TMPDIR/nocaddy/caddy"
  PATH="$BATS_TEST_TMPDIR/nocaddy:/nonexistent" \
    APT_STUB_FAIL=1 NS_BS_STEPS=1 run bootstrap_apply
  assert_failure 1
  printf '%s\n' "$output" | grep -E '^\[1/11\].*needs you: apt-get failed'
  ! printf '%s\n' "$output" | grep -E '^\[1/11\].*changed'
}

@test "step 1 with failing systemctl reload and restart does not report changed" {
  SYSTEMCTL_STUB_FAIL=1 NS_BS_STEPS=1 run bootstrap_apply
  assert_failure 1
  printf '%s\n' "$output" | grep -E '^\[1/11\].*needs you: systemctl failed'
  ! printf '%s\n' "$output" | grep -E '^\[1/11\].*changed'
}

# an active run pinned to v0.0.9, registered in runs.yaml under NS_CONFIG_DIR
make_active_run() {
  local wt="$BATS_TEST_TMPDIR/wt-act" l
  l="$wt/.nightshift/runs/act-1/ledger.yaml"
  mkdir -p "$wt"
  ns-ledger init "$l" --id act-1 --project app --text x --branch plan/act-1
  ns-ledger set "$l" '.state="running" | .release="v0.0.9"'
  printf '{"runs":[{"id":"act-1","project":"app","worktree":"%s","branch":"plan/act-1"}]}\n' "$wt" \
    >"$NS_CONFIG_DIR/runs.yaml"
}

# a live conductor for act-1: a tmux session whose pane process is alive
make_live_run() {
  make_active_run
  live_process sleep
  export TMUX_STUB_PANE_PID="$LIVE_PID"
  printf 'DIR x\n' >"$TMUX_STUB_DIR/act-1"
}

# live_process <argv0>: a background process named <argv0>, killed in teardown
live_process() {
  bash -c "exec -a '$1' sleep 300" 3>&- >/dev/null 2>&1 &
  LIVE_PID=$!
}

teardown() {
  [ -z "${LIVE_PID:-}" ] || kill "$LIVE_PID" 2>/dev/null || true
}

@test "--upgrade refuses while a run's conductor is live and lists it (ns-46, #78)" {
  make_live_run
  before="$(snapshot)"
  run bootstrap_apply --upgrade v0.1.0
  assert_failure 1
  assert_output_contains "act-1  running  v0.0.9  $LIVE_PID"
  assert_output_contains "--force"
  [ "$before" = "$(snapshot)" ]
}

@test "--upgrade --force proceeds despite a live run (ns-46, #78)" {
  make_live_run
  run bootstrap_apply --upgrade v0.1.0 --force
  assert_success
  [ -d "$NS_BS_ROOT/opt/nightshift/v0.1.0" ]
}

@test "--upgrade with no active runs proceeds without --force (ns-46)" {
  run bootstrap_apply --upgrade v0.1.0
  assert_success
}

@test "--upgrade installs and enables the ns-health timer (step 10, #56)" {
  run bootstrap_apply --upgrade v0.1.0
  assert_success
  printf '%s\n' "$output" | grep -E '^\[10/11\]'
  cmp "$NS_REPO_ROOT/templates/systemd/ns-health.timer" "$NS_USER_HOME/.config/systemd/user/ns-health.timer"
  cmp "$NS_REPO_ROOT/templates/systemd/ns-health.service" "$NS_USER_HOME/.config/systemd/user/ns-health.service"
  grep -F 'systemctl --user enable --now ns-health.timer' "$NS_STUB_LOG"
  : >"$NS_STUB_LOG"
  run bootstrap_apply --upgrade v0.1.0
  assert_success
  grep -F 'systemctl --user enable --now ns-health.timer' "$NS_STUB_LOG"
}

@test "--upgrade installs the units of the release it installs, not of the running copy (#56)" {
  work="$BATS_TEST_TMPDIR/tagwork"
  mkdir -p "$work/templates/systemd"
  cp "$NS_REPO_ROOT"/templates/systemd/ns-gc.* "$NS_REPO_ROOT"/templates/systemd/ns-health.* "$work/templates/systemd/"
  printf '# from v0.2.0\n' >>"$work/templates/systemd/ns-health.timer"
  git -C "$work" add -A
  git -C "$work" commit -q -m units
  git -C "$work" tag v0.2.0
  git -C "$work" push -q origin --tags
  unset NS_BS_TEMPLATES
  run bootstrap_apply --upgrade v0.2.0
  assert_success
  grep -qx '# from v0.2.0' "$NS_USER_HOME/.config/systemd/user/ns-health.timer"
}

@test "a plain run with a live conductor stops before step 1 and lists it (#78)" {
  prepare_tree
  make_live_run
  before="$(snapshot)"
  run bootstrap_apply </dev/null
  assert_failure 1
  assert_output_contains "act-1  running  v0.0.9  $LIVE_PID"
  ! printf '%s\n' "$output" | grep -E '^\[[0-9]+/11\]'
  [ "$before" = "$(snapshot)" ]
  run bootstrap_apply --force </dev/null
  assert_success
  printf '%s\n' "$output" | grep -E '^\[1/11\]'
  [ ! -e "$NS_BS_ROOT/opt/nightshift/.upgrade.lock" ]
}

@test "a running ledger with nothing alive does not block and looks dead (#78)" {
  make_active_run
  run bootstrap_apply --upgrade v0.1.0
  assert_success
  assert_output_contains "act-1"
  assert_output_contains "looks dead"
  assert_output_contains "ns kill act-1"
  [ "$(readlink "$NS_BS_ROOT/opt/nightshift/current")" = v0.1.0 ]
}

@test "runs at a gate, queued or parked are listed but do not block (#72)" {
  make_active_run
  ns-ledger set "$BATS_TEST_TMPDIR/wt-act/.nightshift/runs/act-1/ledger.yaml" '.state="waiting" | .gate="1"'
  run bootstrap_apply --upgrade v0.1.0
  assert_success
  assert_output_contains "act-1  waiting  v0.0.9"
  ! printf '%s\n' "$output" | grep -q 'looks dead'
}

@test "a live worker pid blocks the install (#78)" {
  make_active_run
  ns-ledger set "$BATS_TEST_TMPDIR/wt-act/.nightshift/runs/act-1/ledger.yaml" '.state="parked"'
  live_process sleep
  mkdir -p "$NS_CONFIG_DIR/workers"
  printf 'pid=%s\nrun=act-1\nphase=p1\n' "$LIVE_PID" >"$NS_CONFIG_DIR/workers/act-1--p1.pid"
  run bootstrap_apply --upgrade v0.1.0
  assert_failure 1
  assert_output_contains "act-1  parked  v0.0.9  $LIVE_PID"
}

@test "a live conductor pid blocks the install, also without a tmux session (#78)" {
  make_active_run
  live_process ns-launch
  mkdir -p "$NS_CONFIG_DIR/logs/act-1"
  printf '%s\n' "$LIVE_PID" >"$NS_CONFIG_DIR/logs/act-1/conductor.pid"
  run bootstrap_apply --upgrade v0.1.0
  assert_failure 1
  assert_output_contains "act-1  running  v0.0.9  $LIVE_PID"
}

@test "the tmux session of a run that has no ledger yet blocks the install (#78)" {
  live_process sleep
  export TMUX_STUB_PANE_PID="$LIVE_PID"
  printf 'DIR x\n' >"$TMUX_STUB_DIR/app-7"
  printf 'DIR x\n' >"$TMUX_STUB_DIR/rc"
  run bootstrap_apply --upgrade v0.1.0
  assert_failure 1
  assert_output_contains "app-7  -  -  $LIVE_PID"
  ! printf '%s\n' "$output" | grep -q '^  rc '
}

@test "--check reports a live job and changes nothing (#78)" {
  make_live_run
  before="$(snapshot)"
  RUNUSER_STUB_EXEC=1 run bootstrap --check
  assert_output_contains "act-1  running  v0.0.9  $LIVE_PID"
  [ "$before" = "$(snapshot)" ]
}

@test "the upgrade lock is held during the steps and removed afterwards (#78)" {
  printf '#!/bin/sh\n[ -e "%s" ] && echo held >>"%s"\n' "$NS_BS_ROOT/opt/nightshift/.upgrade.lock" \
    "$BATS_TEST_TMPDIR/lock.seen" >"$BATS_TEST_TMPDIR/lockcheck.sh"
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/lockcheck.sh" run bootstrap_apply --upgrade v0.1.0
  assert_success
  grep -q held "$BATS_TEST_TMPDIR/lock.seen"
  [ ! -e "$NS_BS_ROOT/opt/nightshift/.upgrade.lock" ]
}

@test "a second bootstrap refuses while a live one holds the upgrade lock (#78)" {
  mkdir -p "$NS_BS_ROOT/opt/nightshift"
  live_process /opt/nightshift/current/bin/bootstrap.sh
  printf 'pid=%s\n' "$LIVE_PID" >"$NS_BS_ROOT/opt/nightshift/.upgrade.lock"
  run bootstrap_apply --upgrade v0.1.0
  assert_failure 1
  assert_output_contains "holds"
  [ ! -e "$NS_BS_ROOT/opt/nightshift/v0.1.0" ]
  [ -e "$NS_BS_ROOT/opt/nightshift/.upgrade.lock" ]
}

@test "bootstrap waits for a conductor start in flight under the queue lock (#78 review)" {
  make_active_run
  ns-ledger set "$BATS_TEST_TMPDIR/wt-act/.nightshift/runs/act-1/ledger.yaml" '.state="queued"'
  live_process sleep
  export TMUX_STUB_PANE_PID="$LIVE_PID"
  # ns new / ns resume hold the queue lock from their late lock check to the tmux start
  (
    flock 9
    : >"$BATS_TEST_TMPDIR/held"
    sleep 0.5
    printf 'DIR x\n' >"$TMUX_STUB_DIR/act-1"
  ) 9>>"$NS_CONFIG_DIR/queue.lock" 3>&- >/dev/null 2>&1 &
  until [ -e "$BATS_TEST_TMPDIR/held" ]; do sleep 0.1; done
  run bootstrap_apply --upgrade v0.1.0
  assert_failure 1
  assert_output_contains "act-1  queued  v0.0.9  $LIVE_PID"
  [ ! -e "$NS_BS_ROOT/opt/nightshift/v0.1.0" ]
}

@test "a queue lock that stays busy refuses the install unless --force (#78 review)" {
  make_active_run
  mkdir -p "$NS_CONFIG_DIR"
  (
    flock 9
    : >"$BATS_TEST_TMPDIR/held"
    # hold the lock until the test is done with both attempts (bounded: 30s)
    for _ in $(seq 300); do [ -e "$BATS_TEST_TMPDIR/release" ] && break; sleep 0.1; done
  ) 9>>"$NS_CONFIG_DIR/queue.lock" 3>&- >/dev/null 2>&1 &
  until [ -e "$BATS_TEST_TMPDIR/held" ]; do sleep 0.1; done
  NS_BS_QUEUE_WAIT=1 run bootstrap_apply --upgrade v0.1.0
  assert_failure 1
  assert_output_contains "queue lock"
  [ ! -e "$NS_BS_ROOT/opt/nightshift/v0.1.0" ]
  [ ! -e "$NS_BS_ROOT/opt/nightshift/.upgrade.lock" ]
  NS_BS_QUEUE_WAIT=1 run bootstrap_apply --upgrade v0.1.0 --force
  assert_success
  [ -d "$NS_BS_ROOT/opt/nightshift/v0.1.0" ]
  : >"$BATS_TEST_TMPDIR/release"
}

@test "pid files that are symlinks or huge are not read (#78 review)" {
  make_active_run
  live_process ns-launch
  mkdir -p "$NS_CONFIG_DIR/logs/act-1" "$NS_CONFIG_DIR/workers"
  ln -s /dev/zero "$NS_CONFIG_DIR/logs/act-1/conductor.pid"
  printf 'pid=%s\n' "$LIVE_PID" >"$BATS_TEST_TMPDIR/real.pid"
  ln -s "$BATS_TEST_TMPDIR/real.pid" "$NS_CONFIG_DIR/workers/act-1--p1.pid"
  run timeout 60 env NS_BS_TEST=1 RUNUSER_STUB_EXEC=1 "$NS_REPO_ROOT/bin/bootstrap.sh" --upgrade v0.1.0
  assert_success
  assert_output_contains "looks dead"
  rm "$NS_CONFIG_DIR/logs/act-1/conductor.pid"
  # a regular file: only its first bytes are read
  { printf '%s' "$LIVE_PID"; head -c 100000 /dev/zero | tr '\0' 7; printf '\n'; } >"$NS_CONFIG_DIR/logs/act-1/conductor.pid"
  rm "$NS_CONFIG_DIR/workers/act-1--p1.pid"
  run timeout 60 env NS_BS_TEST=1 RUNUSER_STUB_EXEC=1 "$NS_REPO_ROOT/bin/bootstrap.sh" --upgrade v0.1.0
  assert_success
  assert_output_contains "looks dead"
}

@test "a conductor pid file that points at a live process other than ns-launch is ignored (#78 review)" {
  make_active_run
  live_process sleep
  mkdir -p "$NS_CONFIG_DIR/logs/act-1"
  printf '%s\n' "$LIVE_PID" >"$NS_CONFIG_DIR/logs/act-1/conductor.pid"
  run bootstrap_apply --upgrade v0.1.0
  assert_success
  assert_output_contains "looks dead"
}

@test "control characters in ledger fields are not printed (#78 review)" {
  make_active_run
  l="$BATS_TEST_TMPDIR/wt-act/.nightshift/runs/act-1/ledger.yaml"
  ns-ledger set "$l" '.state="parked"'
  # written by hand: ns-ledger would refuse the value (bootstrap.sh reads ledgers as they are)
  sed -i 's/^release: .*/release: "v0.0.9\\e]0;pwned\\a\\e[2J"/' "$l"
  grep -q '^release: "v0.0.9\\e' "$l"
  run bootstrap_apply --upgrade v0.1.0
  assert_success
  assert_output_contains "act-1  parked  v0.0.9]0;pwned[2J"
  ! printf '%s' "$output" | grep -q $'\e'
  ! printf '%s' "$output" | grep -q $'\a'
}

@test "a lock held by a live process that is not bootstrap.sh is stale (#78 review)" {
  live_process sleep
  mkdir -p "$NS_BS_ROOT/opt/nightshift"
  printf 'pid=%s\n' "$LIVE_PID" >"$NS_BS_ROOT/opt/nightshift/.upgrade.lock"
  run bootstrap_apply --upgrade v0.1.0
  assert_success
  [ -d "$NS_BS_ROOT/opt/nightshift/v0.1.0" ]
  [ ! -e "$NS_BS_ROOT/opt/nightshift/.upgrade.lock" ]
}

#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  FIX="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIX/.claude"
  cat >"$FIX/.claude/project-profile.yaml" <<'EOF'
project: nightshift-sandbox
prefix: sbx
commands:
  setup: "true"
git: {}
stacks: [python]
EOF
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  BARE="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T1 --yes >/dev/null
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  LEDGER="$WT/.nightshift/runs/sbx-12/ledger.yaml"
  PROJ="$(dirname "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)")"
  # ns new left a stub tmux session behind; start from "no session"
  rm -f "$TMUX_STUB_DIR/sbx-12"
}

teardown() {
  [ -z "${FAKE_BS_PID:-}" ] || kill "$FAKE_BS_PID" 2>/dev/null || true
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }
lget() { ns-ledger get "$LEDGER" "$1"; }

@test "a parked run resumes: session, state, event and push" {
  ns-ledger set "$LEDGER" '.state="parked"'
  run ns resume sbx-12
  assert_success
  [ "$output" = "resumed sbx-12" ]
  [ "$(lget .state)" = running ]
  [ "$(lget '.events[-1].type')" = resumed ]
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
  grep -q '^CMD exec .*ns-launch sbx-12 --resume$' "$TMUX_STUB_DIR/sbx-12"
  git -C "$BARE" log plan/sbx-12 --format=%s | grep -q 'ns-ledger: sbx-12 running'
}

@test "a running run with a session is already running" {
  ns-ledger set "$LEDGER" '.state="running"'
  : >"$TMUX_STUB_DIR/sbx-12"
  run ns resume sbx-12
  assert_success
  [ "$output" = "sbx-12 is already running" ]
}

@test "a parked run with a stale session gets a new session" {
  ns-ledger set "$LEDGER" '.state="parked"'
  printf 'CMD stale\n' >"$TMUX_STUB_DIR/sbx-12"
  run ns resume sbx-12
  assert_success
  grep -q 'ns-launch sbx-12 --resume' "$TMUX_STUB_DIR/sbx-12"
  ! grep -q 'CMD stale' "$TMUX_STUB_DIR/sbx-12"
}

@test "an unknown run exits 1" {
  run ns resume sbx-99
  assert_failure 1
  assert_output_contains "unknown run sbx-99"
}

@test "a deleted worktree is rebuilt from the local branch" {
  ns-ledger set "$LEDGER" '.state="parked"'
  ns-ledger checkpoint "$LEDGER" --push
  rm -rf "$WT"
  run ns resume sbx-12
  assert_success
  [ -f "$LEDGER" ]
  [ "$(lget .state)" = running ]
}

@test "a deleted worktree and local branch are rebuilt from origin" {
  ns-ledger set "$LEDGER" '.state="parked"'
  ns-ledger checkpoint "$LEDGER" --push
  git -C "$PROJ" worktree remove --force "$WT"
  git -C "$PROJ" branch -D plan/sbx-12 >/dev/null
  run ns resume sbx-12
  assert_success
  [ -f "$LEDGER" ]
  [ "$(lget .state)" = running ]
}

@test "a branch that is gone locally and remotely exits 1" {
  git -C "$PROJ" worktree remove --force "$WT"
  git -C "$PROJ" branch -D plan/sbx-12 >/dev/null
  git -C "$BARE" branch -D plan/sbx-12 >/dev/null
  git -C "$PROJ" update-ref -d refs/remotes/origin/plan/sbx-12
  run ns resume sbx-12
  assert_failure 1
  assert_output_contains "cannot rebuild sbx-12: branch plan/sbx-12 is on neither this machine nor origin"
}

@test "a done run has nothing to resume" {
  ns-ledger set "$LEDGER" '.state="done"'
  run ns resume sbx-12
  assert_success
  [ "$output" = "sbx-12 is done; nothing to resume" ]
  [ ! -f "$TMUX_STUB_DIR/sbx-12" ]
}

@test "a run at a gate waits for the owner" {
  ns-ledger set "$LEDGER" '.state="waiting" | .gate="1"'
  run ns resume sbx-12
  assert_success
  [ "$output" = "sbx-12 waits for the owner at gate 1: edit the desk documents, then ns approve sbx-12" ]
  [ ! -f "$TMUX_STUB_DIR/sbx-12" ]
}

@test "a phase whose trailer is on the feature branch becomes merged" {
  git -C "$WT" branch feature/12 origin/main
  git -C "$WT" worktree add -q "$BATS_TEST_TMPDIR/featwt" feature/12
  git -C "$BATS_TEST_TMPDIR/featwt" commit -q --allow-empty -m "Merge phase p1-alpha" -m "Plan-Phase: p1-alpha"
  git -C "$BATS_TEST_TMPDIR/featwt" push -q origin feature/12
  ns-ledger set "$LEDGER" '.state="parked" | .feature_branch="feature/12" | .phases=[
    {id:"p1-alpha",title:"a",state:"running",branch:null,worktree:null,attempts:1,review_rounds:0},
    {id:"p2-beta",title:"b",state:"running",branch:null,worktree:null,attempts:1,review_rounds:0}]'
  run ns resume sbx-12
  assert_success
  [ "$(lget '.phases[0].state')" = merged ]
  [ "$(lget '.phases[1].state')" = pending ]
  lget '.events[].note' | grep -q 'reconciled p1-alpha as merged'
}

@test "a queued phase becomes pending on resume, so the new conductor schedules it (#10 review)" {
  git -C "$WT" branch feature/12 origin/main
  git -C "$WT" push -q origin feature/12
  ns-ledger set "$LEDGER" '.state="parked" | .feature_branch="feature/12" | .phases=[
    {id:"p1-alpha",title:"a",state:"queued",branch:null,worktree:null,attempts:0,review_rounds:0},
    {id:"p2-beta",title:"b",state:"review",branch:null,worktree:null,attempts:1,review_rounds:0}]'
  run ns resume sbx-12
  assert_success
  [ "$(lget '.phases[0].state')" = pending ]
  [ "$(lget '.phases[1].state')" = review ]
  lget '.events[].note' | grep -q 'reconciled p1-alpha as pending: queued for a pool slot'
}

@test "the reconcile reads the trailer from the profile of the project's --branch (#14)" {
  # the profile on e2e/x sets a custom phase trailer; main keeps the default
  git -C "$WT" worktree add -q -b e2e/x "$BATS_TEST_TMPDIR/branchwt" origin/main
  printf 'project: nightshift-sandbox\nprefix: sbx\ncommands:\n  setup: "true"\ngit:\n  phase_trailer: Run-Phase\nstacks: [python]\n' \
    >"$BATS_TEST_TMPDIR/branchwt/.claude/project-profile.yaml"
  git -C "$BATS_TEST_TMPDIR/branchwt" commit -q -am "branch profile"
  git -C "$BATS_TEST_TMPDIR/branchwt" push -q origin e2e/x
  cfg="$NS_CONFIG_DIR/projects.yaml"
  python3 "$NS_REPO_ROOT/bin/lib/nsyaml.py" to-json "$cfg" | jq '.projects[0].branch = "e2e/x"' |
    python3 "$NS_REPO_ROOT/bin/lib/nsyaml.py" from-json "$cfg"
  git -C "$WT" branch feature/12 origin/main
  git -C "$WT" worktree add -q "$BATS_TEST_TMPDIR/featwt" feature/12
  git -C "$BATS_TEST_TMPDIR/featwt" commit -q --allow-empty -m "Merge phase p1-alpha" -m "Run-Phase: p1-alpha"
  git -C "$BATS_TEST_TMPDIR/featwt" push -q origin feature/12
  ns-ledger set "$LEDGER" '.state="parked" | .feature_branch="feature/12" | .phases=[
    {id:"p1-alpha",title:"a",state:"running",branch:null,worktree:null,attempts:1,review_rounds:0}]'
  run ns resume sbx-12
  assert_success
  [ "$(lget '.phases[0].state')" = merged ]
  lget '.events[].note' | grep -q 'reconciled p1-alpha as merged'
}

@test "--all resumes parked and crashed runs and leaves waiting and done alone" {
  ns new sbx-13 --tier T1 --yes >/dev/null
  ns new sbx-14 --tier T1 --yes >/dev/null
  ns new sbx-15 --tier T1 --yes >/dev/null
  local n
  for n in 13 14 15; do rm -f "$TMUX_STUB_DIR/sbx-$n"; done
  ns-ledger set "$LEDGER" '.state="parked"'
  ns-ledger set "$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-13/.nightshift/runs/sbx-13/ledger.yaml" '.state="running"'
  ns-ledger set "$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-14/.nightshift/runs/sbx-14/ledger.yaml" '.state="waiting" | .gate="1"'
  ns-ledger set "$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-15/.nightshift/runs/sbx-15/ledger.yaml" '.state="done"'
  run ns resume --all
  assert_success
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
  [ -f "$TMUX_STUB_DIR/sbx-13" ]
  [ ! -f "$TMUX_STUB_DIR/sbx-14" ]
  [ ! -f "$TMUX_STUB_DIR/sbx-15" ]
}

@test "resume launches the release the run started on (ns-46)" {
  mkdir -p "$BATS_TEST_TMPDIR/opt"
  ln -s "$NS_REPO_ROOT" "$BATS_TEST_TMPDIR/opt/v0.0.9"
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  ns-ledger set "$LEDGER" '.state="parked" | .release="v0.0.9"'
  run ns resume sbx-12
  assert_success
  grep -q "$BATS_TEST_TMPDIR/opt/v0.0.9/bin/ns-launch sbx-12 --resume" "$TMUX_STUB_DIR/sbx-12"
}

@test "resume dies when the pinned release is gone (ns-46)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$NS_OPT"
  ns-ledger set "$LEDGER" '.state="parked" | .release="v0.0.1"'
  run ns resume sbx-12
  assert_failure
  assert_output_contains "v0.0.1"
}

@test "resume --all fails and starts nothing when the pinned release is gone (ns-46)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$NS_OPT"
  ns-ledger set "$LEDGER" '.state="parked" | .release="v0.0.1"'
  run ns resume --all
  assert_failure
  assert_output_contains "v0.0.1"
  [ ! -f "$TMUX_STUB_DIR/sbx-12" ]
  [ "$(lget .state)" = parked ]
}

@test "a release value that is not a tag is refused (ns-46)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$NS_OPT/x/bin" "$BATS_TEST_TMPDIR/fakehome/bin"
  : >"$NS_OPT/x/bin/ns-launch"
  chmod +x "$NS_OPT/x/bin/ns-launch"
  printf '#!/usr/bin/env bash\necho ../x\n' >"$BATS_TEST_TMPDIR/fakehome/bin/ns-ledger"
  chmod +x "$BATS_TEST_TMPDIR/fakehome/bin/ns-ledger"
  run bash -c 'NS_HOME="$1"; source "$2/bin/lib/common.sh"; source "$2/bin/lib/runs.sh"; ns_release_home /nonexistent' _ \
    "$BATS_TEST_TMPDIR/fakehome" "$NS_REPO_ROOT"
  assert_failure
  assert_output_contains "not a release tag"
}

@test "ns-launch re-execs the pinned release (ns-46)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$NS_OPT/v0.0.9/bin"
  cat >"$NS_OPT/v0.0.9/bin/ns-launch" <<EOS
#!/usr/bin/env bash
printf 'HOME=%s PINNED=%s ARGS=%s\n' "\$NS_HOME" "\${NS_LAUNCH_PINNED:-}" "\$*" >"$BATS_TEST_TMPDIR/stub.out"
EOS
  chmod +x "$NS_OPT/v0.0.9/bin/ns-launch"
  ns-ledger set "$LEDGER" '.release="v0.0.9"'
  run ns-launch sbx-12 --resume
  assert_success
  [ "$(cat "$BATS_TEST_TMPDIR/stub.out")" = "HOME=$NS_OPT/v0.0.9 PINNED=1 ARGS=sbx-12 --resume" ]
}

@test "ns-launch dies when the pinned release is gone (ns-46)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$NS_OPT"
  ns-ledger set "$LEDGER" '.release="v0.0.1"'
  run ns-launch sbx-12 --resume
  assert_failure
  assert_output_contains "v0.0.1"
}

# fake_home: an NS_HOME ($FH) that is this checkout, except that its ns-ledger fails every call
# whose arguments match the glob $NS_LEDGER_FAIL and runs the real ns-ledger otherwise
fake_home() {
  FH="$BATS_TEST_TMPDIR/fakehome"
  mkdir -p "$FH/bin"
  local f
  for f in "$NS_REPO_ROOT"/*; do
    [ "$(basename "$f")" = bin ] || ln -s "$f" "$FH/"
  done
  for f in "$NS_REPO_ROOT"/bin/*; do ln -s "$f" "$FH/bin/"; done
  rm "$FH/bin/ns" "$FH/bin/ns-ledger"
  cp "$NS_REPO_ROOT/bin/ns" "$FH/bin/ns"
  cat >"$FH/bin/ns-ledger" <<EOS
#!/usr/bin/env bash
# shellcheck disable=SC2053
if [ -n "\${NS_LEDGER_FAIL:-}" ] && [[ "\$*" == \$NS_LEDGER_FAIL ]]; then
  echo "ns-ledger stub: failing \$1" >&2
  exit 1
fi
exec "$NS_REPO_ROOT/bin/ns-ledger" "\$@"
EOS
  chmod +x "$FH/bin/ns-ledger"
}

# fail_tmux_start: a tmux on $PATH whose new-session fails
fail_tmux_start() {
  local real_tmux
  real_tmux=$(command -v tmux)
  mkdir -p "$BATS_TEST_TMPDIR/failbin"
  cat >"$BATS_TEST_TMPDIR/failbin/tmux" <<EOS
#!/usr/bin/env bash
[ "\${1:-}" != new-session ] || exit 1
exec "$real_tmux" "\$@"
EOS
  chmod +x "$BATS_TEST_TMPDIR/failbin/tmux"
  export PATH="$BATS_TEST_TMPDIR/failbin:$PATH"
}

@test "a failed resumed event after the state was set rolls the run back (#96)" {
  fake_home
  ns-ledger set "$LEDGER" '.state="parked"'
  NS_LEDGER_FAIL='event * resumed *' run "$FH/bin/ns" resume sbx-12
  assert_failure
  [ "$(lget .state)" = parked ]
  [ "$(lget '.queued_for_slot // false')" = false ]
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
}

@test "a failed ledger commit (ns-ledger checkpoint exits non-zero) after the state was set rolls the run back (#96)" {
  fake_home
  ns-ledger set "$LEDGER" '.state="parked"'
  NS_LEDGER_FAIL='checkpoint *' run "$FH/bin/ns" resume sbx-12
  assert_failure
  [ "$(lget .state)" = parked ]
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
}

@test "a failed resumed event during ns dequeue leaves the run queued (#96)" {
  fake_home
  ns-ledger set "$LEDGER" '.state="queued" | .queued_for_slot=true'
  NS_LEDGER_FAIL='event * resumed *' run "$FH/bin/ns" dequeue
  assert_output_contains "0 started, 1 still queued"
  [ "$(lget .state)" = queued ]
  [ "$(lget .queued_for_slot)" = true ]
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
}

@test "a failed tmux start of ns resume on a queued run keeps it in the queue (#96)" {
  ns-ledger set "$LEDGER" '.state="queued" | .queued_for_slot=true'
  fail_tmux_start
  run ns resume sbx-12
  assert_failure
  [ "$(lget .state)" = queued ]
  [ "$(lget .queued_for_slot)" = true ]
}

@test "a failed ledger write during the reconcile stops the resume (#96)" {
  fake_home
  ns-ledger set "$LEDGER" '.state="parked" | .feature_branch="feature/sbx-12" | .phases=[
    {id:"p1-alpha",title:"a",state:"running",branch:null,worktree:null,attempts:1,review_rounds:0}]'
  NS_LEDGER_FAIL='set *phases*' run "$FH/bin/ns" resume sbx-12
  assert_failure
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
  [ "$(lget .state)" = parked ]
  [ "$(lget '[.events[] | select(.note // "" | test("reconciled"))] | length')" = 0 ]
}

@test "--all leaves runs stopped by the owner alone; ns resume <id> restarts them (#96)" {
  ns new sbx-13 --tier T1 --yes >/dev/null
  rm -f "$TMUX_STUB_DIR/sbx-13"
  L13="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-13/.nightshift/runs/sbx-13/ledger.yaml"
  ns-ledger set "$LEDGER" '.state="parked"'
  run ns kill sbx-13
  assert_success
  [ "$(ns-ledger get "$L13" .state)" = stopped ]
  run ns resume --all
  assert_success
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
  [ ! -e "$TMUX_STUB_DIR/sbx-13" ]
  [ "$(ns-ledger get "$L13" .state)" = stopped ]
  assert_output_contains "sbx-13 is stopped; resume it by name: ns resume sbx-13"
  run ns resume sbx-13
  assert_success
  [ -f "$TMUX_STUB_DIR/sbx-13" ]
  [ "$(ns-ledger get "$L13" .state)" = running ]
}

@test "--all with only stopped runs starts nothing (#96)" {
  ns-ledger set "$LEDGER" '.state="stopped"'
  run ns resume --all
  assert_success
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
  assert_output_contains "nothing to resume"
}

# fake_release <tag>: a copy of this checkout's bin/ and plugin dirs under $NS_OPT/<tag>
fake_release() {
  local r="$NS_OPT/$1"
  mkdir -p "$r/plugins/ns" "$r/plugins/ns-python"
  cp -a "$NS_REPO_ROOT/bin" "$r/"
  cp "$NS_REPO_ROOT/plugins/ns-python/stack.yaml" "$r/plugins/ns-python/"
}

@test "ns-launch loads the plugins of the run's release when it is not current (#72)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  fake_release v0.0.9
  fake_release v0.1.0
  ln -s v0.1.0 "$NS_OPT/current"
  ns-ledger set "$LEDGER" '.release="v0.0.9"'
  run ns-launch sbx-12 --resume
  assert_success
  args="$BATS_TEST_TMPDIR/claude/call-1.args"
  [ "$(grep -A1 -x -- '--plugin-dir' "$args" | grep -v -x -- '--plugin-dir' | grep -v -x -- '--')" = "$NS_OPT/v0.0.9/plugins/ns
$NS_OPT/v0.0.9/plugins/ns-python" ]
  # on the current release the marketplace plugins (pinned to current) are used
  ns-ledger set "$LEDGER" '.release="v0.1.0"'
  run ns-launch sbx-12 --resume
  assert_success
  [ "$(grep -c -x -- '--plugin-dir' "$BATS_TEST_TMPDIR/claude/call-2.args")" = 0 ]
  # an explicit NS_PLUGIN_DIRS (a dev checkout, the e2e harness) wins
  ns-ledger set "$LEDGER" '.release="v0.0.9"'
  NS_PLUGIN_DIRS=/p/one run ns-launch sbx-12 --resume
  assert_success
  [ "$(grep -A1 -x -- '--plugin-dir' "$BATS_TEST_TMPDIR/claude/call-3.args" | tail -1)" = /p/one ]
}

@test "ns new, ns resume and ns approve refuse while the upgrade lock is held (#78)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$NS_OPT"
  fake_bootstrap
  printf 'pid=%s\n' "$FAKE_BS_PID" >"$NS_OPT/.upgrade.lock"
  run ns new sbx-13 --tier T1 --yes
  assert_failure 1
  assert_output_contains "upgrade"
  [ ! -e "$TMUX_STUB_DIR/sbx-13" ]
  ! grep -q sbx-13 "$NS_CONFIG_DIR/runs.yaml"
  ns-ledger set "$LEDGER" '.state="parked"'
  run ns resume sbx-12
  assert_failure 1
  assert_output_contains "upgrade"
  [ "$(lget .state)" = parked ]
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
  ns-ledger set "$LEDGER" '.state="waiting" | .gate="1"'
  before=$(git -C "$WT" rev-parse HEAD)
  run ns approve sbx-12 --yes
  assert_failure 1
  assert_output_contains "upgrade"
  [ "$(lget .gate)" = 1 ]
  [ "$(git -C "$WT" rev-parse HEAD)" = "$before" ]
}

@test "a stale upgrade lock (its bootstrap is gone) is ignored with a warning (#78)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$NS_OPT"
  bash -c 'exit 0' &
  dead=$!
  wait "$dead"
  printf 'pid=%s\n' "$dead" >"$NS_OPT/.upgrade.lock"
  ns-ledger set "$LEDGER" '.state="parked"'
  run ns resume sbx-12
  assert_success
  assert_output_contains "stale upgrade lock"
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
}

@test "a resume that reaches the start while the upgrade lock is held queues the run (#78)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$NS_OPT"
  ns-ledger set "$LEDGER" '.state="parked"'
  # the lock appears after ns resume's first check: call the start step directly
  fake_bootstrap
  printf 'pid=%s\n' "$FAKE_BS_PID" >"$NS_OPT/.upgrade.lock"
  run bash -c 'source "$1/bin/lib/common.sh"; source "$1/bin/lib/runs.sh"; source "$1/bin/lib/queue.sh"
    source "$1/bin/lib/ns-resume.sh"; ns_resume_start sbx-12 "$2" "$3" parked "$1"' _ "$NS_REPO_ROOT" "$WT" "$LEDGER"
  [ "$status" -eq 10 ]
  assert_output_contains "upgrade"
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
  [ "$(lget .state)" = queued ]
  [ "$(lget .queued_for_slot)" = true ]
  # ns dequeue leaves it queued while the lock is held
  run bash -c 'source "$1/bin/lib/common.sh"; source "$1/bin/lib/runs.sh"; source "$1/bin/lib/queue.sh"
    source "$1/bin/lib/ns-resume.sh"; NS_DEQUEUE=1 ns_resume_start sbx-12 "$2" "$3" queued "$1"' _ "$NS_REPO_ROOT" "$WT" "$LEDGER"
  [ "$status" -eq 10 ]
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
}

@test "an upgrade lock whose pid is a live process other than bootstrap.sh is stale (#78 review)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$NS_OPT"
  sleep 300 3>&- >/dev/null 2>&1 &
  FAKE_BS_PID=$!
  printf 'pid=%s\n' "$FAKE_BS_PID" >"$NS_OPT/.upgrade.lock"
  ns-ledger set "$LEDGER" '.state="parked"'
  run ns resume sbx-12
  assert_success
  assert_output_contains "stale upgrade lock"
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
}

@test "an upgrade lock without a readable pid counts as held and names the recovery (#78 review)" {
  export NS_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$NS_OPT"
  printf 'garbage\n' >"$NS_OPT/.upgrade.lock"
  ns-ledger set "$LEDGER" '.state="parked"'
  run ns resume sbx-12
  assert_failure 1
  assert_output_contains "remove $NS_OPT/.upgrade.lock as root"
  [ ! -e "$TMUX_STUB_DIR/sbx-12" ]
}

@test "ns-launch writes conductor.pid while it runs and removes only its own (#78 review)" {
  pidf="$NS_CONFIG_DIR/logs/sbx-12/conductor.pid"
  printf 'cat "%s" >"%s"\n' "$pidf" "$BATS_TEST_TMPDIR/seen.pid" >"$BATS_TEST_TMPDIR/look.sh"
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/look.sh" run ns-launch sbx-12 --resume
  assert_success
  [[ $(cat "$BATS_TEST_TMPDIR/seen.pid") =~ ^[0-9]+$ ]]
  [ ! -e "$pidf" ]
  # another ns-launch took the file over meanwhile: it stays
  printf 'printf "%%s\\n" 999999 >"%s"\n' "$pidf" >"$BATS_TEST_TMPDIR/take.sh"
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/take.sh" run ns-launch sbx-12 --resume
  assert_success
  [ "$(cat "$pidf")" = 999999 ]
}

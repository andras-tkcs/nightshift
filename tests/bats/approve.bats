#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  export GH_STUB_RESPONSES="$NS_REPO_ROOT/tests/fixtures/gh-stub/responses/approve"
  FIX="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIX/.claude"
  cat >"$FIX/.claude/project-profile.yaml" <<'EOP'
project: nightshift-sandbox
prefix: sbx
commands:
  setup: "true"
git: {}
stacks: [python]
EOP
  printf '# sandbox\n' >"$FIX/README.md"
  BARE="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

# gate_setup: sandbox project sbx and non-sandbox project oth, both at gate 1 with documents published
gate_setup() {
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  make_remote acme/other "$FIX"
  ns project add andras-tkcs/nightshift-sandbox --prefix sbx --sandbox >/dev/null
  ns project add acme/other --prefix oth >/dev/null
  ns new sbx-12 --tier T1 --yes >/dev/null
  ns new oth-3 --tier T1 --yes >/dev/null
  rm -f "$TMUX_STUB_DIR/sbx-12" "$TMUX_STUB_DIR/oth-3"
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  RUNDIR="$WT/.nightshift/runs/sbx-12"
  LEDGER="$RUNDIR/ledger.yaml"
  DESK="$NS_DESK_DIR/nightshift-sandbox/runs/sbx-12"
  printf '# Plan\n\nDo the thing.\n' >"$RUNDIR/plan.md"
  printf '<html><body>handoff</body></html>\n' >"$RUNDIR/handoff.html"
  OLEDGER=$(python3 "$NS_REPO_ROOT/bin/lib/nsyaml.py" to-json "$NS_CONFIG_DIR/runs.yaml" | jq -r ".runs[] | select(.id == \"oth-3\") | .worktree + \"/.nightshift/runs/oth-3/ledger.yaml\"")
  printf '# Plan\n' >"$(dirname "$OLEDGER")/plan.md"
  ns-ledger state "$LEDGER" waiting --gate 1
  ns-ledger state "$OLEDGER" waiting --gate 1
  ns publish sbx-12 RUN/plan.md RUN/handoff.html >/dev/null
  ns publish oth-3 RUN/plan.md >/dev/null
}

lget() { ns-ledger get "$LEDGER" "$1"; }

@test "no gate: message and exit 0" {
  gate_setup
  ns-ledger set "$LEDGER" '.gate=null'
  run ns approve sbx-12
  assert_success
  [ "$output" = "sbx-12 is not waiting at a gate; nothing to approve" ]
}

@test "--yes on a non-sandbox project exits 2" {
  gate_setup
  run ns approve oth-3 --yes
  assert_failure 2
  assert_output_contains "--yes is only allowed for projects added with --sandbox"
  [ "$(ns-ledger get "$OLEDGER" .gate)" = 1 ]
}

@test "the diff names both labels; n changes nothing" {
  gate_setup
  printf '# Plan\n\nDo the other thing.\n' >"$DESK/plan.md"
  before=$(git -C "$WT" rev-parse HEAD)
  ledger_before=$(cat "$LEDGER")
  run ns approve sbx-12 <<<"n"
  assert_failure 1
  assert_output_contains "--- branch:.nightshift/runs/sbx-12/plan.md"
  assert_output_contains "+++ desk:plan.md"
  assert_output_contains "+Do the other thing."
  assert_output_contains "Nothing changed."
  [ "$(git -C "$WT" rev-parse HEAD)" = "$before" ]
  [ "$(cat "$LEDGER")" = "$ledger_before" ]
  grep -q 'Do the thing' "$RUNDIR/plan.md"
  [ ! -f "$TMUX_STUB_DIR/sbx-12" ]
}

@test "--yes on the sandbox project commits the edit, releases the gate and resumes" {
  gate_setup
  printf '# Plan\n\nDo the other thing.\n' >"$DESK/plan.md"
  printf '<html><body>changed on the desk</body></html>\n' >"$DESK/handoff.html"
  run ns approve sbx-12 --yes
  assert_success
  assert_output_contains "approved gate 1 of sbx-12"
  grep -q 'Do the other thing' "$RUNDIR/plan.md"
  grep -q 'handoff' "$RUNDIR/handoff.html"
  ! grep -q 'changed on the desk' "$RUNDIR/handoff.html"
  git -C "$WT" log --format=%B -n 20 | grep -qx 'Approved-By: owner'
  git -C "$WT" log --format=%s | grep -qx 'ns: approve sbx-12 gate 1'
  [ "$(lget '.gate // "none"')" = none ]
  [ "$(lget '[.events[].type] | index("approved") != null')" = true ]
  [ -f "$TMUX_STUB_DIR/sbx-12" ]
  grep -q -- '--resume$' "$TMUX_STUB_DIR/sbx-12"
  run ns approve sbx-12
  assert_success
  assert_output_contains "nothing to approve"
}

@test "state done at gate 2: message, exit 0, nothing changes" {
  gate_setup
  ns-ledger set "$LEDGER" '.gate="2" | .state="done" | .step="done"'
  ledger_before=$(cat "$LEDGER")
  before=$(git -C "$WT" rev-parse HEAD)
  run ns approve sbx-12 --yes
  assert_success
  assert_output_contains "sbx-12 is at gate 2, the pull request review: read the handoff, then merge the PR on GitHub (/ns:review sbx-12); nothing to approve"
  [ "$(cat "$LEDGER")" = "$ledger_before" ]
  [ "$(git -C "$WT" rev-parse HEAD)" = "$before" ]
  [ ! -f "$TMUX_STUB_DIR/sbx-12" ]
}

@test "a token-shaped string on the desk is refused and nothing changes" {
  gate_setup
  printf '# Plan\n\nghp_%s\n' "$(printf 'a%.0s' $(seq 36))" >"$DESK/plan.md"
  ledger_before=$(cat "$LEDGER")
  before=$(git -C "$WT" rev-parse HEAD)
  run ns approve sbx-12 --yes
  assert_failure 1
  assert_output_contains "token"
  [ "$(cat "$LEDGER")" = "$ledger_before" ]
  [ "$(git -C "$WT" rev-parse HEAD)" = "$before" ]
  grep -q 'Do the thing' "$RUNDIR/plan.md"
  [ ! -f "$TMUX_STUB_DIR/sbx-12" ]
}

@test "a .published source that escapes the worktree is refused" {
  gate_setup
  printf '# Plan\n\nchanged\n' >"$DESK/plan.md"
  printf 'plan.md\t../../escape.md\n' >"$DESK/.published"
  ledger_before=$(cat "$LEDGER")
  run ns approve sbx-12 --yes
  assert_failure 1
  assert_output_contains "outside the worktree"
  [ "$(cat "$LEDGER")" = "$ledger_before" ]
  [ ! -e "$NS_CODING_DIR/worktrees/escape.md" ]
  [ ! -f "$TMUX_STUB_DIR/sbx-12" ]
}

# onboarding variant

onboard_setup() {
  mkdir -p "$BATS_TEST_TMPDIR/bare"
  printf '# bare\n' >"$BATS_TEST_TMPDIR/bare/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$BATS_TEST_TMPDIR/bare"
  ns project add andras-tkcs/nightshift-sandbox --prefix sbx --sandbox >/dev/null
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-onboard"
  RUNDIR="$WT/.nightshift/runs/sbx-onboard"
  LEDGER="$RUNDIR/ledger.yaml"
  DESK="$NS_DESK_DIR/nightshift-sandbox/runs/sbx-onboard"
  printf 'project: nightshift-sandbox\nprefix: sbx\ncommands:\n  setup: "true"  # guess: from README\n' >"$RUNDIR/project-profile.yaml"
  printf 'REQUIRED_CHECKS=ci\n' >"$RUNDIR/ns-github.env"
  printf -- '---\nname: sbx-invariants\ndescription: d\nuser-invocable: false\n---\nInvariants.\n' >"$RUNDIR/sbx-invariants.md"
  printf '# notes\n' >"$RUNDIR/onboarding-notes.md"
  rm -f "$TMUX_STUB_DIR/sbx-onboard"
  ns-ledger state "$LEDGER" waiting --gate 1
  ns publish sbx-onboard RUN/project-profile.yaml RUN/ns-github.env RUN/sbx-invariants.md RUN/onboarding-notes.md >/dev/null
  printf 'project: nightshift-sandbox\nprefix: sbx\ncommands:\n  setup: "make"  # guess: edited\n' >"$DESK/project-profile.yaml"
}

@test "onboarding: n leaves everything unchanged and the diff shows the edit" {
  onboard_setup
  ledger_before=$(cat "$LEDGER")
  run ns approve sbx-onboard <<<"n"
  assert_failure 1
  assert_output_contains '+  setup: "make"'
  assert_output_contains "Nothing changed."
  [ "$(cat "$LEDGER")" = "$ledger_before" ]
  ! git -C "$BARE" rev-parse -q --verify refs/heads/nightshift/onboard
  ! grep -q 'pr create' "$GH_STUB_LOG"
}

@test "onboarding: --yes pushes nightshift/onboard, opens a PR and finishes the run" {
  onboard_setup
  run ns approve sbx-onboard --yes
  assert_success
  assert_output_contains "opened https://github.com/andras-tkcs/nightshift-sandbox/pull/7; merge it, then ns new works for andras-tkcs/nightshift-sandbox"
  run git -C "$BARE" diff --name-status main nightshift/onboard
  [ "$output" = "$(printf 'A\t.claude/ns-github.env\nA\t.claude/project-profile.yaml\nA\t.claude/skills/sbx-invariants/SKILL.md')" ]
  git -C "$BARE" show nightshift/onboard:.claude/project-profile.yaml | grep -q 'setup: "make"'
  git -C "$BARE" log -1 --format=%B nightshift/onboard | grep -qx 'Approved-By: owner'
  git -C "$BARE" log -1 --format=%s nightshift/onboard | grep -qx 'ns: onboard andras-tkcs/nightshift-sandbox'
  grep -q 'pr create --base main --head nightshift/onboard --title Onboard andras-tkcs/nightshift-sandbox to Nightshift --body-file' "$GH_STUB_LOG"
  ! grep -q 'pr merge' "$GH_STUB_LOG"
  [ "$(ns-ledger get "$LEDGER" .state)" = done ]
  [ "$(ns-ledger get "$LEDGER" .pr)" = "https://github.com/andras-tkcs/nightshift-sandbox/pull/7" ]
  [ "$(ns-ledger get "$LEDGER" '.gate // "none"')" = none ]
  [ ! -f "$TMUX_STUB_DIR/sbx-onboard" ]
}

@test "onboarding: a second approve prints nothing to approve and restarts nothing" {
  onboard_setup
  ns approve sbx-onboard --yes >/dev/null
  ledger_before=$(cat "$LEDGER")
  run ns approve sbx-onboard --yes
  assert_success
  assert_output_contains "nothing to approve"
  [ "$(cat "$LEDGER")" = "$ledger_before" ]
  [ ! -f "$TMUX_STUB_DIR/sbx-onboard" ]
}

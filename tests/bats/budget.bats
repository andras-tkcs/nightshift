#!/usr/bin/env bats
# Budgets on every tier (R-BUD-1) and no budget charged for the gap before a resume (#9).

load helpers

HOOKS="$NS_REPO_ROOT/plugins/ns/hooks"

setup() {
  ns_test_setup
  FIX="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIX/.claude"
  cat >"$FIX/.claude/project-profile.yaml" <<'EOF'
project: nightshift-sandbox
prefix: sbx
commands:
  setup: "true"
  test: "true"
git: {}
stacks: [python]
EOF
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  BARE="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx --sandbox >/dev/null
  SBX="$NS_CODING_DIR/worktrees/nightshift-sandbox"
  export NS_WORKER_MODE=bypassPermissions
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }
ledger() { printf '%s' "$SBX-$1/.nightshift/runs/$1/ledger.yaml"; }
lget() { ns-ledger get "$(ledger "$1")" "$2"; }

# new_run <id> <tier>: a run with no session, state running, 1 h of budget left of the tier's limit
new_run() {
  ns new "$1" --tier "$2" --yes >/dev/null
  rm -f "$TMUX_STUB_DIR/$1"
  ns-ledger state "$(ledger "$1")" running --no-gate >/dev/null
}

# over_budget <id>: budget used up (used = limit)
over_budget() {
  ns-ledger set "$(ledger "$1")" '.budget.limit = 2 | .budget.used = 2'
}

# assert_escalated <id>: state waiting at gate 1.5, a budget event, escalation.md on the desk
assert_escalated() {
  [ "$(lget "$1" .state)" = waiting ]
  [ "$(lget "$1" .gate)" = 1.5 ]
  [ "$(lget "$1" '[.events[] | select(.type == "budget")] | length')" -ge 1 ]
  esc="$SBX-$1/.nightshift/runs/$1/escalation.md"
  [ -f "$esc" ]
  head -n1 "$esc" | grep -q '^# Budget exceeded'
  grep -q '^## Question' "$esc"
  grep -q '^## Owner.s answer' "$esc"
  grep -q '^budget_hours: 2$' "$esc"
  [ -f "$NS_DESK_DIR/nightshift-sandbox/runs/$1/escalation.md" ]
}

# --- the ledger ---------------------------------------------------------------------------------

@test "budget-exceeded is true once used reaches the limit" {
  new_run sbx-10 T0
  ns-ledger set "$(ledger sbx-10)" '.budget.limit = 2 | .budget.used = 1.99'
  run ns-ledger budget-exceeded "$(ledger sbx-10)"
  assert_failure 1
  ns-ledger set "$(ledger sbx-10)" '.budget.used = 2'
  run ns-ledger budget-exceeded "$(ledger sbx-10)"
  assert_success
}

@test "going back to running resets budget.since: a parked gap is not charged" {
  new_run sbx-10 T0
  L=$(ledger sbx-10)
  ns-ledger set "$L" '.state = "parked"'
  ns-ledger set "$L" '.budget.used = 0.5 | .budget.since = "2026-10-02T18:00:00Z"'
  ns-ledger state "$L" running --no-gate
  ns-ledger checkpoint "$L"
  [ "$(lget sbx-10 .budget.used)" = 0.5 ]
  [ "$(lget sbx-10 .budget.since)" = "$NS_NOW" ]
}

@test "leaving running charges the time up to then; a gate wait is not charged" {
  new_run sbx-10 T0
  L=$(ledger sbx-10)
  ns-ledger set "$L" '.budget.used = 0 | .budget.since = "2026-10-02T20:00:00Z"'
  ns-ledger state "$L" waiting --gate 1
  [ "$(lget sbx-10 .budget.used)" = 1 ]
  NS_NOW=2026-10-03T09:00:00Z ns-ledger checkpoint "$L"
  [ "$(lget sbx-10 .budget.used)" = 1 ]
}

@test "unpause after a usage-limit pause does not charge the pause" {
  new_run sbx-12 T2
  L=$(ledger sbx-12)
  ns-ledger set "$L" '.budget.used = 0 | .budget.since = "2026-10-02T20:00:00Z"'
  ns-conductor pause sbx-12 >/dev/null
  [ "$(lget sbx-12 .budget.used)" = 1 ]
  NS_NOW=2026-10-03T01:00:00Z ns-conductor unpause sbx-12 >/dev/null
  [ "$(lget sbx-12 .budget.used)" = 1 ]
}

# --- every resume path ----------------------------------------------------------------------------

# gap <id> <state>: the run sits in <state> since 18:00, three hours before NS_NOW, with 0.5 h used
gap() {
  local L
  L=$(ledger "$1")
  ns-ledger set "$L" ".state = \"$2\""
  ns-ledger set "$L" '.budget.used = 0.5 | .budget.since = "2026-10-02T18:00:00Z"'
}

@test "ns resume of a crashed run does not charge the gap" {
  new_run sbx-11 T1
  gap sbx-11 running
  run ns resume sbx-11
  assert_success
  [ "$(lget sbx-11 .state)" = running ]
  [ "$(lget sbx-11 .budget.used)" = 0.5 ]
  [ "$(lget sbx-11 .budget.since)" = "$NS_NOW" ]
}

@test "ns resume of a parked run does not charge the gap" {
  new_run sbx-11 T1
  gap sbx-11 parked
  run ns resume sbx-11
  assert_success
  [ "$(lget sbx-11 .budget.used)" = 0.5 ]
}

@test "ns resume of a stopped run does not charge the gap" {
  new_run sbx-11 T1
  gap sbx-11 stopped
  run ns resume sbx-11
  assert_success
  [ "$(lget sbx-11 .budget.used)" = 0.5 ]
}

@test "ns resume --all does not charge the gap of a parked or a crashed run" {
  new_run sbx-10 T0
  new_run sbx-11 T1
  gap sbx-10 parked
  gap sbx-11 running
  run ns resume --all
  assert_success
  [ "$(lget sbx-10 .budget.used)" = 0.5 ]
  [ "$(lget sbx-11 .budget.used)" = 0.5 ]
}

@test "after a reboot, ns up and ns resume --all do not charge the downtime" {
  new_run sbx-10 T0
  gap sbx-10 parked
  run ns up
  assert_output_contains "parked: sbx-10"
  [ "$(lget sbx-10 .state)" = parked ]
  run ns resume --all
  assert_success
  [ "$(lget sbx-10 .state)" = running ]
  [ "$(lget sbx-10 .budget.used)" = 0.5 ]
}

@test "ns dequeue does not charge the time a run waited in the queue" {
  new_run sbx-11 T1
  gap sbx-11 queued
  ns-ledger set "$(ledger sbx-11)" '.queued_for_slot = true'
  run ns dequeue
  assert_success
  assert_output_contains "1 started"
  [ "$(lget sbx-11 .state)" = running ]
  [ "$(lget sbx-11 .budget.used)" = 0.5 ]
}

@test "ns approve does not charge the gate wait" {
  new_run sbx-11 T1
  RUNDIR="$SBX-sbx-11/.nightshift/runs/sbx-11"
  printf '# Plan\n' >"$RUNDIR/plan.md"
  ns-ledger set "$(ledger sbx-11)" '.budget.used = 0.5 | .budget.since = "2026-10-02T18:00:00Z"'
  NS_NOW=2026-10-02T18:00:00Z ns-conductor gate sbx-11 1 RUN/plan.md >/dev/null
  run ns approve sbx-11 --yes
  assert_success
  [ "$(lget sbx-11 .state)" = running ]
  [ "$(lget sbx-11 .budget.used)" = 0.5 ]
}

@test "ns-launch: the conductor's state running after a queue wait does not charge the wait" {
  ns new sbx-11 --tier T1 --yes >/dev/null
  ns-ledger set "$(ledger sbx-11)" '.budget.since = "2026-10-02T18:00:00Z"'
  cat >"$BATS_TEST_TMPDIR/conductor.sh" <<'EOF'
ns-ledger state "$NS_LEDGER" running --no-gate
ns-ledger checkpoint "$NS_LEDGER"
EOF
  CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/conductor.sh" run ns-launch sbx-11
  assert_success
  [ "$(lget sbx-11 .budget.used)" = 0 ]
}

# --- a deterministic check on every tier ----------------------------------------------------------

@test "T0: checks escalates at gate 1.5 and exits 4 when the budget is used up" {
  new_run sbx-10 T0
  ns-conductor fix-branch sbx-10 >/dev/null
  over_budget sbx-10
  run ns-conductor checks sbx-10 feature
  assert_failure 4
  assert_output_contains "budget"
  assert_output_contains "gate 1.5"
  assert_escalated sbx-10
  [ "$(cat "$NS_CONFIG_DIR/logs/sbx-10/feature.checks.rc")" = 4 ]
}

@test "T0: should-stop escalates at gate 1.5 and exits 4; under budget it exits 1" {
  new_run sbx-10 T0
  run ns-conductor should-stop sbx-10
  assert_failure 1
  over_budget sbx-10
  run ns-conductor should-stop sbx-10
  assert_failure 4
  assert_escalated sbx-10
}

@test "T1: review-round escalates before counting a round" {
  new_run sbx-11 T1
  ns-conductor fix-branch sbx-11 >/dev/null
  over_budget sbx-11
  run ns-conductor review-round sbx-11 fix
  assert_failure 4
  assert_escalated sbx-11
  [ "$(lget sbx-11 '[.phases[] | select(.id == "fix")] | length')" = 0 ]
}

@test "T1: the integrator's stack-base escalates before the PR" {
  new_run sbx-11 T1
  ns-conductor fix-branch sbx-11 >/dev/null
  over_budget sbx-11
  run ns-conductor stack-base sbx-11
  assert_failure 4
  assert_escalated sbx-11
}

@test "T2: start escalates at gate 1.5 and exits 4" {
  new_run sbx-12 T2
  over_budget sbx-12
  run ns-conductor start sbx-12 p1-alpha
  assert_failure 4
  assert_output_contains "budget exceeded"
  assert_escalated sbx-12
}

@test "T3: should-stop escalates; the budget check counts the time since the last checkpoint" {
  new_run sbx-13 T3
  L=$(ledger sbx-13)
  ns-ledger set "$L" '.budget.limit = 2 | .budget.used = 1.5 | .budget.since = "2026-10-02T20:00:00Z"'
  run ns-conductor should-stop sbx-13
  assert_failure 4
  assert_escalated sbx-13
  [ "$(lget sbx-13 .budget.used)" = 2.5 ]
}

@test "a stop request wins over the budget: should-stop exits 0 and park stops the run" {
  new_run sbx-12 T2
  over_budget sbx-12
  ns-ledger set "$(ledger sbx-12)" '.stop_requested = "stopped"'
  run ns-conductor should-stop sbx-12
  assert_success
}

@test "budget-check at a gate does not escalate again; park keeps an open gate" {
  new_run sbx-12 T2
  over_budget sbx-12
  run ns-conductor budget-check sbx-12
  assert_failure 4
  n=$(lget sbx-12 '[.events[] | select(.type == "budget")] | length')
  run ns-conductor budget-check sbx-12
  assert_failure 4
  [ "$(lget sbx-12 '[.events[] | select(.type == "budget")] | length')" = "$n" ]
  run ns-conductor park sbx-12
  assert_success
  [ "$(lget sbx-12 .state)" = waiting ]
  [ "$(lget sbx-12 .gate)" = 1.5 ]
}

@test "ns approve with a raised budget_hours sets the new limit and resumes" {
  new_run sbx-11 T1
  over_budget sbx-11
  run ns-conductor should-stop sbx-11
  assert_failure 4
  DESK="$NS_DESK_DIR/nightshift-sandbox/runs/sbx-11"
  sed -i 's/^budget_hours: 2$/budget_hours: 3.5/' "$DESK/escalation.md"
  run ns approve sbx-11 --yes
  assert_success
  [ "$(lget sbx-11 .budget.limit)" = 3.5 ]
  [ "$(lget sbx-11 .state)" = running ]
  run ns-conductor should-stop sbx-11
  assert_failure 1
}

# --- hooks -----------------------------------------------------------------------------------------

# budget_hook <id>: run the PreToolUse budget hook as the conductor session of <id>
budget_hook() {
  run env NS_RUN_ID="$1" NS_LEDGER="$(ledger "$1")" NS_RUN_HOME="$NS_HOME" bash -c \
    'printf "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}" | "$1/budget.sh" 2>&1' _ "$HOOKS"
}

@test "the budget hook allows tool calls under budget, outside a run and in a worker" {
  new_run sbx-10 T0
  budget_hook sbx-10
  assert_success
  over_budget sbx-10
  run bash -c 'printf "{}" | "$1/budget.sh"' _ "$HOOKS"
  assert_success
  run env NS_RUN_ID=sbx-10 NS_LEDGER="$(ledger sbx-10)" NS_WORKER=1 bash -c 'printf "{}" | "$1/budget.sh"' _ "$HOOKS"
  assert_success
  [ "$(lget sbx-10 .state)" = running ]
}

@test "the budget hook escalates a T0 run that works past its budget and blocks its tool calls" {
  new_run sbx-10 T0
  L=$(ledger sbx-10)
  ns-ledger set "$L" '.budget.limit = 2 | .budget.used = 1.5 | .budget.since = "2026-10-02T20:00:00Z"'
  budget_hook sbx-10
  assert_failure 2
  assert_output_contains "budget"
  assert_output_contains "end the session"
  assert_escalated sbx-10
  budget_hook sbx-10
  assert_failure 2
}

@test "the Stop hook escalates a run that ends its session over budget" {
  new_run sbx-11 T1
  over_budget sbx-11
  NS_RUN_ID=sbx-11 NS_RUN_HOME="$NS_HOME" NS_LEDGER="$(ledger sbx-11)" run "$HOOKS/checkpoint.sh"
  assert_success
  assert_escalated sbx-11
}

# --- review of #140 ----------------------------------------------------------------------------------

@test "ns resume of a crashed run with no free slot queues it without charging the dead gap" {
  printf 'max_runs: 1\n' >"$NS_CONFIG_DIR/config.yaml"
  new_run sbx-10 T0
  new_run sbx-11 T1
  : >"$TMUX_STUB_DIR/sbx-10"
  gap sbx-11 running
  run ns resume sbx-11
  assert_success
  [ "$(lget sbx-11 .state)" = queued ]
  [ "$(lget sbx-11 .budget.used)" = 0.5 ]
}

@test "ns resume --all with more crashed runs than max_runs charges none of them the dead gap" {
  printf 'max_runs: 1\n' >"$NS_CONFIG_DIR/config.yaml"
  new_run sbx-10 T0
  new_run sbx-11 T1
  gap sbx-10 running
  gap sbx-11 running
  run ns resume --all
  assert_success
  [ "$(lget sbx-10 .state) $(lget sbx-11 .state)" = "running queued" ]
  [ "$(lget sbx-10 .budget.used)" = 0.5 ]
  [ "$(lget sbx-11 .budget.used)" = 0.5 ]
}

@test "ns drain of a dead run parks it without charging the dead gap" {
  new_run sbx-11 T1
  gap sbx-11 running
  run ns drain --timeout 1
  [ "$(lget sbx-11 .state)" = parked ]
  [ "$(lget sbx-11 .budget.used)" = 0.5 ]
}

@test "ns kill of a dead run stops it without charging the dead gap" {
  new_run sbx-11 T1
  gap sbx-11 running
  run ns kill sbx-11 </dev/null
  [ "$(lget sbx-11 .state)" = stopped ]
  [ "$(lget sbx-11 .budget.used)" = 0.5 ]
}

@test "frequent checkpoints carry the time below the rounding step instead of dropping it" {
  new_run sbx-11 T1
  L=$(ledger sbx-11)
  ns-ledger set "$L" '.budget.used = 0 | .budget.since = "2026-10-02T21:00:00Z"'
  for t in 21:00:10 21:00:20 21:00:30 21:00:40 21:00:50 21:01:00 21:01:10 21:01:12; do
    NS_NOW="2026-10-02T${t}Z" ns-ledger checkpoint "$L"
  done
  [ "$(lget sbx-11 .budget.used)" = 0.02 ]
  [ "$(lget sbx-11 .budget.since)" = 2026-10-02T21:01:12Z ]
}

@test "two budget checks at once escalate once" {
  new_run sbx-12 T2
  over_budget sbx-12
  ns-conductor budget-check sbx-12 >/dev/null 2>&1 &
  ns-conductor budget-check sbx-12 >/dev/null 2>&1 || true
  wait || true
  [ "$(lget sbx-12 '[.events[] | select(.type == "budget")] | length')" = 1 ]
  assert_escalated sbx-12
}

@test "a budget gate left without its escalation document is completed by the next check" {
  new_run sbx-11 T1
  over_budget sbx-11
  # a budget check killed right after it opened the gate
  ns-ledger event "$(ledger sbx-11)" budget "budget used up: 2 h of 2 h"
  ns-ledger state "$(ledger sbx-11)" waiting --gate 1.5 --note "budget used up"
  run ns-conductor budget-check sbx-11
  assert_failure 4
  assert_escalated sbx-11
}

@test "after stack-base passed, the integrator may finish: the hook and the checks allow it" {
  new_run sbx-11 T1
  ns-conductor fix-branch sbx-11 >/dev/null
  # stack-base passed: it recorded stacked_on (the gh stub has no PR list here)
  ns-ledger set "$(ledger sbx-11)" '.step = "integrate" | .stacked_on = "main"'
  over_budget sbx-11
  budget_hook sbx-11
  assert_success
  run ns-conductor budget-check sbx-11
  assert_success
  [ "$(lget sbx-11 .state)" = running ]
  run ns-conductor stack-base sbx-11
  assert_failure 4
}

@test "the hook says when the escalation failed, and still denies" {
  new_run sbx-10 T0
  over_budget sbx-10
  mkdir -p "$BATS_TEST_TMPDIR/home/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/home/bin/ns-conductor"
  chmod +x "$BATS_TEST_TMPDIR/home/bin/ns-conductor"
  run env NS_RUN_ID=sbx-10 NS_LEDGER="$(ledger sbx-10)" NS_RUN_HOME="$BATS_TEST_TMPDIR/home" bash -c \
    'printf "{}" | "$1/budget.sh" 2>&1' _ "$HOOKS"
  assert_failure 2
  assert_output_contains "could not escalate"
  [[ $output != *"waits at gate 1.5"* ]]
}

@test "the hook says so on stderr when PyYAML is missing, and allows" {
  new_run sbx-10 T0
  over_budget sbx-10
  mkdir -p "$BATS_TEST_TMPDIR/noyaml"
  printf 'raise ImportError("no yaml here")\n' >"$BATS_TEST_TMPDIR/noyaml/yaml.py"
  run env PYTHONPATH="$BATS_TEST_TMPDIR/noyaml" NS_RUN_ID=sbx-10 NS_LEDGER="$(ledger sbx-10)" bash -c \
    'printf "{}" | "$1/budget.sh" 2>&1' _ "$HOOKS"
  assert_success
  assert_output_contains "PyYAML"
}

@test "hooks.json gives the budget hook a timeout above its budget-check timeout" {
  t=$(jq '.hooks.PreToolUse[] | .hooks[] | select(.command | test("budget.sh")) | .timeout' "$HOOKS/hooks.json")
  s=$(sed -n 's/^CHECK_TIMEOUT = \([0-9]*\)$/\1/p' "$HOOKS/lib/budget.py")
  [ -n "$t" ] && [ -n "$s" ]
  [ "$t" -gt "$s" ]
}

@test "the Stop hook claims gate 1.5 only when it escalated" {
  new_run sbx-11 T1
  over_budget sbx-11
  ns-ledger state "$(ledger sbx-11)" waiting --gate 1
  NS_RUN_ID=sbx-11 NS_RUN_HOME="$NS_HOME" NS_LEDGER="$(ledger sbx-11)" run "$HOOKS/checkpoint.sh"
  assert_success
  [[ $output != *"gate 1.5"* ]]
  [ "$(lget sbx-11 .gate)" = 1 ]
}

@test "check-auto's nested claude does not see the run's NS_RUN_ID and NS_LEDGER" {
  printf 'printf "%%s|%%s\\n" "${NS_RUN_ID:-unset}" "${NS_LEDGER:-unset}" >"%s/seen"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/env.sh"
  NS_RUN_ID=sbx-10 NS_LEDGER=/x CLAUDE_STUB_MODE="script:$BATS_TEST_TMPDIR/env.sh" run ns-conductor check-auto
  assert_success
  [ "$(cat "$BATS_TEST_TMPDIR/seen")" = "unset|unset" ]
}

@test "ns approve warns about a budget_hours line it cannot read and keeps the limit" {
  new_run sbx-11 T1
  over_budget sbx-11
  run ns-conductor should-stop sbx-11
  DESK="$NS_DESK_DIR/nightshift-sandbox/runs/sbx-11"
  sed -i 's/^budget_hours: 2$/budget_hours: 6h/' "$DESK/escalation.md"
  run ns approve sbx-11 --yes
  assert_output_contains "cannot read budget_hours: 6h"
  [ "$(lget sbx-11 .budget.limit)" = 2 ]
}

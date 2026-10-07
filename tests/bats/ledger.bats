#!/usr/bin/env bats

load helpers
bats_require_minimum_version 1.5.0

setup() {
  ns_test_setup
  make_remote acme/app
  CLONE="$BATS_TEST_TMPDIR/app"
  git clone -q "$GH_STUB_REMOTES/acme/app.git" "$CLONE"
  git -C "$CLONE" switch -q -c plan/app-x1
  L="$CLONE/.nightshift/runs/app-x1/ledger.yaml"
}

init_ledger() {
  ns-ledger init "$L" --id app-x1 --project app --text "do the thing" --branch plan/app-x1
}

@test "init creates the ledger and .gitignore" {
  run init_ledger
  assert_success
  [ -f "$L" ]
  [ "$(cat "$(dirname "$L")/.gitignore")" = "$(printf '*.lock\n*.tmp.*')" ]
  run ns-ledger get "$L" '.state + " " + .step + " " + .events[0].type + " " + .request.text'
  assert_success
  [ "$output" = "queued intake created do the thing" ]
}

@test "init with --issue stores an integer" {
  run ns-ledger init "$L" --id app-12 --project app --issue 12 --branch plan/app-12
  assert_success
  run ns-ledger get "$L" '.request | keys[] + "=" + (.issue | tostring)'
  [ "$output" = "issue=12" ]
}

@test "init twice exits 1" {
  init_ledger
  run init_ledger
  assert_failure 1
  assert_output_contains "ledger exists: $L"
}

@test "init rejects a bad id" {
  run ns-ledger init "$L" --id BAD --project app --text x --branch b
  assert_failure 1
  assert_output_contains "not written"
  [ ! -e "$L" ]
}

@test "set with a valid program writes" {
  init_ledger
  run ns-ledger set "$L" '.step = "phases" | .tags = ["python"]'
  assert_success
  run ns-ledger get "$L" '.step + " " + .tags[0]'
  [ "$output" = "phases python" ]
}

@test "set with an invalid state exits 1 and leaves the file byte-identical" {
  init_ledger
  before="$(sha256sum "$L")"
  run ns-ledger set "$L" '.state = "bogus"'
  assert_failure 1
  assert_output_contains "not written"
  [ "$(sha256sum "$L")" = "$before" ]
}

@test "event appends" {
  init_ledger
  run ns-ledger event "$L" note "hello"
  assert_success
  run ns-ledger get "$L" '.events[-1] | .type + ":" + .note'
  [ "$output" = "note:hello" ]
  run ns-ledger event "$L" "Bad Type" "x"
  assert_failure 1
}

@test "state with --gate 1" {
  init_ledger
  run ns-ledger state "$L" waiting --gate 1 --note "plan ready"
  assert_success
  run ns-ledger get "$L" '.state + " " + .gate + " | " + .events[-1].type + " | " + .events[-1].note'
  [ "$output" = "waiting 1 | state | waiting gate 1: plan ready" ]
  run ns-ledger state "$L" running --no-gate
  assert_success
  run ns-ledger get "$L" '.gate'
  [ "$output" = "null" ]
}

@test "tier sets limit" {
  init_ledger
  run ns-ledger tier "$L" T2 --source owner --hours 6 --recommended T1 --tags python,risk:policy
  assert_success
  run ns-ledger get "$L" '[.tier, .tier_source, .tier_recommended, (.budget.limit | tostring), (.tags | join("+")), .events[-1].type] | join(" ")'
  [ "$output" = "T2 owner T1 6 python+risk:policy tier" ]
}

@test "checkpoint adds elapsed hours while running" {
  init_ledger
  ns-ledger state "$L" running
  NS_NOW=2026-10-02T22:30:00Z run ns-ledger checkpoint "$L"
  assert_success
  run ns-ledger get "$L" '.budget.used, .budget.since'
  [ "${lines[0]}" = "1.5" ]
  [ "${lines[1]}" = "2026-10-02T22:30:00Z" ]
}

@test "checkpoint adds nothing while paused" {
  init_ledger
  ns-ledger state "$L" running
  ns-ledger set "$L" '.budget.paused = true'
  NS_NOW=2026-10-02T22:30:00Z run ns-ledger checkpoint "$L"
  assert_success
  run ns-ledger get "$L" '.budget.used, .budget.since'
  [ "${lines[0]}" = "0" ]
  [ "${lines[1]}" = "2026-10-02T22:30:00Z" ]
}

@test "checkpoint adds nothing when not running" {
  init_ledger
  NS_NOW=2026-10-02T22:30:00Z run ns-ledger checkpoint "$L"
  assert_success
  run ns-ledger get "$L" '.budget.used'
  [ "$output" = "0" ]
}

@test "checkpoint commits only the ledger directory" {
  init_ledger
  printf 'x\n' >>"$CLONE/README.md"
  run ns-ledger checkpoint "$L"
  assert_success
  [ "$(git -C "$CLONE" log -1 --format=%s)" = "ns-ledger: app-x1 queued" ]
  [ "$(git -C "$CLONE" show --name-only --format= HEAD | sort | tr '\n' ' ')" = ".nightshift/runs/app-x1/.gitignore .nightshift/runs/app-x1/ledger.yaml " ]
  run git -C "$CLONE" status --porcelain
  [ "$output" = " M README.md" ]
}

@test "checkpoint with no change makes no commit" {
  init_ledger
  ns-ledger checkpoint "$L"
  head="$(git -C "$CLONE" rev-parse HEAD)"
  ns-ledger checkpoint "$L"
  # updated and since are unchanged because NS_NOW is fixed
  [ "$(git -C "$CLONE" rev-parse HEAD)" = "$head" ]
}

@test "checkpoint --push updates the remote branch" {
  init_ledger
  run ns-ledger checkpoint "$L" --push
  assert_success
  [ "$(git -C "$CLONE" rev-parse HEAD)" = "$(git -C "$GH_STUB_REMOTES/acme/app.git" rev-parse plan/app-x1)" ]
}

@test "push to a missing remote appends push-failed and exits 0" {
  init_ledger
  git -C "$CLONE" remote set-url origin "$BATS_TEST_TMPDIR/nowhere.git"
  run ns-ledger checkpoint "$L" --push
  assert_success
  run ns-ledger get "$L" '.events[-1].type'
  [ "$output" = "push-failed" ]
}

@test "a truncated file is restored from HEAD with a recovered event" {
  init_ledger
  ns-ledger checkpoint "$L"
  size="$(stat -c %s "$L")"
  head -c $((size / 2)) "$L" >"$L.half"
  mv "$L.half" "$L"
  run ns-ledger get "$L" '.id'
  assert_success
  assert_output_contains "app-x1"
  assert_output_contains "restored from"
  run ns-ledger get "$L" '.events[-1].type'
  [ "$output" = "recovered" ]
  run ns-ledger validate "$L"
  assert_success
}

@test "corrupt with no commit exits 1" {
  init_ledger
  printf 'state: [\n' >"$L"
  run ns-ledger get "$L"
  assert_failure 1
  assert_output_contains "ledger $L is corrupt and has no valid committed version"
}

@test "validate exits 0 on a good ledger" {
  init_ledger
  run ns-ledger validate "$L"
  assert_success
}

@test "budget-exceeded both ways" {
  init_ledger
  run ns-ledger budget-exceeded "$L"
  assert_failure 1
  ns-ledger set "$L" '.budget.limit = 1 | .budget.used = 1.5'
  run ns-ledger budget-exceeded "$L"
  assert_success
  ns-ledger set "$L" '.budget.used = 0.5'
  run ns-ledger budget-exceeded "$L"
  assert_failure 1
}

@test "two concurrent events both end up in the file" {
  init_ledger
  ns-ledger event "$L" note one &
  ns-ledger event "$L" note two &
  wait
  run ns-ledger get "$L" '[.events[].note | select(. == "one" or . == "two")] | sort | join(",")'
  [ "$output" = "one,two" ]
}

@test "--help prints usage" {
  run ns-ledger --help
  assert_success
  assert_output_contains "usage: ns-ledger"
}

@test "init records the release tag when NS_HOME is /opt/nightshift/<tag> (ns-46)" {
  mkdir -p "$BATS_TEST_TMPDIR/opt"
  ln -s "$NS_REPO_ROOT" "$BATS_TEST_TMPDIR/opt/v0.1.0"
  NS_OPT="$BATS_TEST_TMPDIR/opt" NS_HOME="$BATS_TEST_TMPDIR/opt/v0.1.0" init_ledger
  run ns-ledger get "$L" '.release'
  assert_success
  [ "$output" = "v0.1.0" ]
}

@test "init records no release for a v-named NS_HOME outside NS_OPT or a name that is not a tag (#72)" {
  mkdir -p "$BATS_TEST_TMPDIR/opt" "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$NS_REPO_ROOT" "$BATS_TEST_TMPDIR/elsewhere/v0.1.0"
  ln -s "$NS_REPO_ROOT" "$BATS_TEST_TMPDIR/opt/v1+x"
  NS_OPT="$BATS_TEST_TMPDIR/opt" NS_HOME="$BATS_TEST_TMPDIR/elsewhere/v0.1.0" init_ledger
  [ "$(ns-ledger get "$L" '.release')" = null ]
  rm -rf "$(dirname "$L")"
  NS_OPT="$BATS_TEST_TMPDIR/opt" NS_HOME="$BATS_TEST_TMPDIR/opt/v1+x" init_ledger
  [ "$(ns-ledger get "$L" '.release')" = null ]
}

@test "ns_ledger_read launches python3 exactly once (ns-101)" {
  init_ledger
  real=$(command -v python3)
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  count="$BATS_TEST_TMPDIR/py-launches"
  : >"$count"
  cat >"$BATS_TEST_TMPDIR/shim/python3" <<SHIM
#!/usr/bin/env bash
echo x >>"$count"
exec "$real" "\$@"
SHIM
  chmod +x "$BATS_TEST_TMPDIR/shim/python3"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" run ns-ledger get "$L" .state
  assert_success
  [ "$output" = "queued" ]
  [ "$(wc -l <"$count")" -eq 1 ]
}

# py_shim [stderr text]: put a python3 on PATH that counts launches and, if given, prints a line
# on stderr first. Sets COUNT.
py_shim() {
  local real
  real=$(command -v python3)
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  COUNT="$BATS_TEST_TMPDIR/py-launches"
  : >"$COUNT"
  cat >"$BATS_TEST_TMPDIR/shim/python3" <<SHIM
#!/usr/bin/env bash
echo x >>"$COUNT"
[ -z "${1:-}" ] || echo "${1:-}" >&2
exec "$real" "\$@"
SHIM
  chmod +x "$BATS_TEST_TMPDIR/shim/python3"
}

@test "ns_ledger_read reads a drift ledger in one python3 launch (ns-120)" {
  init_ledger
  printf 'wip_field: ns-50\n' >>"$L"
  py_shim
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" run ns-ledger get "$L" .state
  assert_success
  [ "$output" = "$(printf 'ns-ledger: warning: ledger has unknown field wip_field; kept\nqueued')" ]
  [ "$(wc -l <"$COUNT")" -eq 1 ]
}

@test "a warning python3 prints on stderr does not become the ledger JSON (ns-120)" {
  init_ledger
  py_shim "DeprecationWarning: something old"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" run --separate-stderr ns-ledger get "$L" .state
  assert_success
  [ "$output" = "queued" ]
  [[ $stderr == *"DeprecationWarning: something old"* ]]
}

@test "a drift ledger with a hard error and no committed version dies with the exact line (ns-120)" {
  init_ledger
  printf 'wip_field: ns-50\ntags: 5\n' >>"$L"
  run --separate-stderr ns-ledger get "$L" .state
  assert_failure 1
  [ "$stderr" = "ns-ledger: ledger $L is corrupt and has no valid committed version: \$.tags: 5 is not of type 'array'; run: ns-ledger validate $L" ]
}

@test "after a recovery the warning names the restored version's unknown fields only (ns-120)" {
  init_ledger
  printf 'old_field: kept\n' >>"$L"
  ns-ledger checkpoint "$L" 2>/dev/null
  printf 'wip_field: ns-50\ntags: 5\n' >>"$L"
  run --separate-stderr ns-ledger get "$L" .state
  assert_success
  [ "$output" = "queued" ]
  [[ $stderr == *"restored from"* ]]
  [[ $stderr == *"ledger has unknown field old_field; kept"* ]]
  [[ $stderr != *"wip_field"* ]]
  grep -q '^old_field: kept' "$L"
  ! grep -q wip_field "$L"
}

@test "drift is a root additionalProperties error and the ledger schema has no root patternProperties (ns-120)" {
  run jq -e 'has("patternProperties") | not' "$NS_REPO_ROOT/schema/ledger.schema.json"
  assert_success
  # With root patternProperties, jsonschema words the error differently; nsyaml.py still calls
  # it drift (by validator) but ns_ledger_keys_filter (by message) would not see the key.
  S="$BATS_TEST_TMPDIR/s.json"
  D="$BATS_TEST_TMPDIR/d.yaml"
  printf '{"type":"object","patternProperties":{"^x_":{}},"additionalProperties":false}\n' >"$S"
  printf 'odd: 1\n' >"$D"
  run python3 "$NS_REPO_ROOT/bin/lib/nsyaml.py" read "$D" "$S"
  assert_success
  [ "${lines[0]}" = '{"odd": 1}' ]
  [[ ${lines[1]} == "$D: \$: 'odd' does not match any of the regexes: '^x_'" ]]
  printf '{"type":"object","additionalProperties":false}\n' >"$S"
  run python3 "$NS_REPO_ROOT/bin/lib/nsyaml.py" read "$D" "$S"
  assert_success
  [ "${lines[1]}" = "$D: \$: Additional properties are not allowed ('odd' was unexpected)" ]
}

@test "set with .step=triage adds exactly one step event; a set that leaves .step alone adds none" {
  T="$BATS_TEST_TMPDIR/step-ledger.yaml"
  ns-ledger init "$T" --id app-x1 --project app --text "do the thing" --branch plan/app-x1
  n0="$(ns-ledger get "$T" '[.events[] | select(.type == "step")] | length')"
  run ns-ledger set "$T" '.step = "triage"'
  assert_success
  [ "$(ns-ledger get "$T" '[.events[] | select(.type == "step")] | length')" = "$((n0 + 1))" ]
  [ "$(ns-ledger get "$T" '[.events[] | select(.type == "step" and .note == "triage")] | length')" = 1 ]
  total="$(ns-ledger get "$T" '.events | length')"
  run ns-ledger set "$T" '.tags = ["python"]'
  assert_success
  [ "$(ns-ledger get "$T" '.events | length')" = "$total" ]
}

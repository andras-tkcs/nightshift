#!/usr/bin/env bats
# ns-83: a dev checkout must not write a live run's ledger, and schema drift must not lock a run out.

load helpers

fixture_vars() {
  FIX="$BATS_TEST_TMPDIR/fixture"
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  LEDGER="$WT/.nightshift/runs/sbx-12/ledger.yaml"
}

# the slow part of the setup, run once per file (ns_cached_fixture)
fixture_build() {
  fixture_vars
  mkdir -p "$FIX/.claude"
  cat >"$FIX/.claude/project-profile.yaml" <<'PROFILE'
project: nightshift-sandbox
prefix: sbx
commands:
  setup: "true"
git: {}
stacks: [python]
PROFILE
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T1 --yes >/dev/null
  rm -f "$TMUX_STUB_DIR/sbx-12"
}

setup() {
  ns_test_setup
  ns_cached_fixture fixture_build
  fixture_vars
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

# Commit the ledger as it is, so recovery cannot rescue it.
commit_ledger() {
  git -C "$WT" add -A
  git -C "$WT" commit -q -m "ledger with drift"
}

@test "a dev checkout refuses to write the live run's ledger" {
  # NS_HOME is the dev checkout (not /opt/nightshift); NS_LEDGER marks the live run's ledger
  export NS_RUN_ID=sbx-12 NS_LEDGER="$LEDGER"
  before="$(sha256sum "$LEDGER")"
  run ns-ledger set "$LEDGER" '.step = "phases"'
  assert_failure 1
  assert_output_contains "live run"
  [ "$(sha256sum "$LEDGER")" = "$before" ]
}

@test "the same dev checkout writes a temp ledger while a live run is marked" {
  TMPL="$BATS_TEST_TMPDIR/tmp-ledger/ledger.yaml"
  ns-ledger init "$TMPL" --id tmp-1 --project app --text x --branch plan/tmp-1
  export NS_RUN_ID=sbx-12 NS_LEDGER="$LEDGER"
  run ns-ledger set "$TMPL" '.step = "phases"'
  assert_success
  [ "$(ns-ledger get "$TMPL" .step)" = phases ]
}

@test "an unknown top-level key is read with a warning by ns ls, status and resume" {
  ns-ledger set "$LEDGER" '.state = "parked"'
  printf 'wip_field: ns-50\n' >>"$LEDGER"
  commit_ledger
  run ns ls
  assert_success
  assert_output_contains "ledger has unknown field wip_field; kept"
  assert_output_contains "sbx-12"
  run ns status sbx-12
  assert_success
  assert_output_contains "ledger has unknown field wip_field; kept"
  run ns resume sbx-12
  assert_success
  assert_output_contains "ledger has unknown field wip_field; kept"
  grep -q '^wip_field: ns-50' "$LEDGER"
}

@test "a type error still fails and the message names the field" {
  printf 'tags: 5\n' >>"$LEDGER"
  commit_ledger
  run ns-ledger validate "$LEDGER"
  assert_failure
  assert_output_contains "tags"
  run ns status sbx-12
  assert_failure
  assert_output_contains "tags"
  assert_output_contains "ns-ledger validate"
}

@test "the home that launched the run writes its own ledger; another checkout cannot" {
  export NS_RUN_ID=sbx-12 NS_LEDGER="$LEDGER" NS_RUN_HOME="$NS_HOME"
  run ns-ledger set "$LEDGER" '.step = "phases"'
  assert_success
  other="$BATS_TEST_TMPDIR/other-checkout"
  mkdir -p "$other"
  cp -r "$NS_HOME"/. "$other"/
  NS_HOME="$other" run "$other/bin/ns-ledger" set "$LEDGER" '.step = "plan"'
  assert_failure 1
  assert_output_contains "live run"
}

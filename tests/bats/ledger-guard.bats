#!/usr/bin/env bats
# ns-120: the live-ledger guard checks the running script's own directory, not only NS_HOME,
# and pins a release run's ledger to that release.

load helpers

setup() {
  ns_test_setup
  OPT="$BATS_TEST_TMPDIR/opt"
  REL="$OPT/v9.9.9"
  mkdir -p "$REL"
  cp -r "$NS_REPO_ROOT/bin" "$NS_REPO_ROOT/schema" "$REL"/
  L="$BATS_TEST_TMPDIR/run/.nightshift/runs/sbx-12/ledger.yaml"
  NS_HOME="$REL" "$REL/bin/ns-ledger" init "$L" --id sbx-12 --project sbx --text x --branch plan/sbx-12
  [ "$(ns-ledger get "$L" .release)" = v9.9.9 ]
  CHECKOUT="$NS_REPO_ROOT"
}

# live <cmd...>: run <cmd> with the variables ns-launch gives a run launched from the fake release.
live() {
  NS_OPT="$OPT" NS_RUN_ID=sbx-12 NS_LEDGER="$L" NS_RUN_HOME="$REL" NS_HOME="$REL" "$@"
}

unchanged() {
  [ "$(ns-ledger get "$L" .step)" = intake ]
}

@test "a checkout's ns-ledger that inherited the run's NS_HOME refuses the live ledger" {
  run live "$CHECKOUT/bin/ns-ledger" set "$L" '.step = "phases"'
  assert_failure 1
  assert_output_contains "refusing to write $L"
  assert_output_contains "live run sbx-12"
  unchanged
}

@test "the release's own ns-ledger with the same variables writes the live ledger" {
  run live "$REL/bin/ns-ledger" set "$L" '.step = "phases"'
  assert_success
  [ "$(ns-ledger get "$L" .step)" = phases ]
}

@test "the release's ns-ledger reached through a symlink writes the live ledger" {
  mkdir -p "$BATS_TEST_TMPDIR/localbin"
  ln -s "$REL/bin/ns-ledger" "$BATS_TEST_TMPDIR/localbin/ns-ledger"
  run live "$BATS_TEST_TMPDIR/localbin/ns-ledger" set "$L" '.step = "phases"'
  assert_success
}

@test "pointing NS_HOME and NS_RUN_HOME at the checkout does not make it the run's release" {
  run env NS_OPT="$OPT" NS_RUN_ID=sbx-12 NS_LEDGER="$L" NS_RUN_HOME="$CHECKOUT" NS_HOME="$CHECKOUT" \
    "$CHECKOUT/bin/ns-ledger" set "$L" '.step = "phases"'
  assert_failure 1
  assert_output_contains "live run sbx-12"
  unchanged
}

@test "an NS_OPT whose release entry links to the checkout does not make it the release" {
  farm="$BATS_TEST_TMPDIR/farm"
  mkdir -p "$farm"
  ln -s "$CHECKOUT" "$farm/v9.9.9"
  run env NS_OPT="$farm" NS_RUN_ID=sbx-12 NS_LEDGER="$L" NS_RUN_HOME="$farm/v9.9.9" NS_HOME="$farm/v9.9.9" \
    "$farm/v9.9.9/bin/ns-ledger" set "$L" '.step = "phases"'
  assert_failure 1
  assert_output_contains "live run sbx-12"
  unchanged
}

@test "the release's script with NS_HOME pointing at a checkout refuses the live ledger" {
  run env NS_OPT="$OPT" NS_RUN_ID=sbx-12 NS_LEDGER="$L" NS_RUN_HOME="$REL" NS_HOME="$CHECKOUT" \
    "$REL/bin/ns-ledger" set "$L" '.step = "phases"'
  assert_failure 1
  assert_output_contains "live run sbx-12"
  unchanged
}

@test "a checkout still writes a temp ledger while the live run is marked" {
  T="$BATS_TEST_TMPDIR/tmp/ledger.yaml"
  ns-ledger init "$T" --id tmp-1 --project app --text x --branch plan/tmp-1
  run live "$CHECKOUT/bin/ns-ledger" set "$T" '.step = "phases"'
  assert_success
  [ "$(ns-ledger get "$T" .step)" = phases ]
}

@test "a symlinked NS_OPT still lets the release write its run's ledger" {
  ln -s "$OPT" "$BATS_TEST_TMPDIR/optlink"
  run env NS_OPT="$BATS_TEST_TMPDIR/optlink" NS_RUN_ID=sbx-12 NS_LEDGER="$L" \
    NS_RUN_HOME="$BATS_TEST_TMPDIR/optlink/v9.9.9" NS_HOME="$BATS_TEST_TMPDIR/optlink/v9.9.9" \
    "$BATS_TEST_TMPDIR/optlink/v9.9.9/bin/ns-ledger" set "$L" '.step = "phases"'
  assert_success
}

@test "without NS_RUN_HOME a release under a symlinked NS_OPT may write a dev run's ledger" {
  ns-ledger set "$L" '.release = null'
  ln -s "$OPT" "$BATS_TEST_TMPDIR/optlink"
  run env NS_OPT="$BATS_TEST_TMPDIR/optlink" NS_RUN_ID=sbx-12 NS_LEDGER="$L" NS_HOME="$REL" \
    "$REL/bin/ns-ledger" set "$L" '.step = "phases"'
  assert_success
  [ "$(ns-ledger get "$L" .step)" = phases ]
}

@test "without NS_RUN_HOME a checkout may not write a dev run's live ledger" {
  ns-ledger set "$L" '.release = null'
  run env NS_OPT="$OPT" NS_RUN_ID=sbx-12 NS_LEDGER="$L" NS_HOME="$REL" \
    "$CHECKOUT/bin/ns-ledger" set "$L" '.step = "phases"'
  assert_failure 1
  unchanged
}

@test "exported shell functions named after the guard's tools do not make a checkout pass" {
  # readlink, dirname, basename and sed functions that map the checkout onto the fake release
  readlink() {
    local a out
    for a in "$@"; do :; done
    out="$(command readlink "$@")"
    case "$out" in
      "$CHECKOUT"*) printf '%s\n' "$REL${out#"$CHECKOUT"}" ;;
      *) printf '%s\n' "$out" ;;
    esac
  }
  dirname() { command dirname "$@" | command sed "s|^$CHECKOUT|$REL|"; }
  basename() { printf 'v9.9.9\n'; }
  export CHECKOUT REL
  export -f readlink dirname basename
  run live "$CHECKOUT/bin/ns-ledger" set "$L" '.step = "phases"'
  unset -f readlink dirname basename
  assert_failure 1
  assert_output_contains "live run sbx-12"
  unchanged
}

# Pins the documented limit (docs/security.md, issue #128): flip this test when live ledgers are marked on disk
# or the release home must be root-owned.
@test "known limit: a copy of the checkout under a fake NS_OPT named after the tag passes" {
  # The guard is a seatbelt against the accidental case (docs/security.md). A deliberate copy or
  # worktree placed at <fake NS_OPT>/<tag> looks like the release; this pins the documented limit.
  fake="$BATS_TEST_TMPDIR/opt2"
  mkdir -p "$fake/v9.9.9"
  cp -r "$CHECKOUT/bin" "$CHECKOUT/schema" "$fake/v9.9.9"/
  run env NS_OPT="$fake" NS_RUN_ID=sbx-12 NS_LEDGER="$L" NS_HOME="$fake/v9.9.9" \
    "$fake/v9.9.9/bin/ns-ledger" set "$L" '.step = "phases"'
  assert_success
}

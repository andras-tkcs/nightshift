#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  FIX="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIX/.claude"
  cp "$NS_REPO_ROOT/tests/fixtures/report/project-profile.yaml" "$FIX/.claude/project-profile.yaml"
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  SBX="$NS_CODING_DIR/worktrees/nightshift-sandbox"
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T2 --yes >/dev/null
  RUNDIR="$SBX-sbx-12/.nightshift/runs/sbx-12"
  cp "$NS_REPO_ROOT/tests/fixtures/report/ledger.yaml" "$RUNDIR/ledger.yaml"
  cp "$NS_REPO_ROOT/tests/fixtures/report/escalation.md" "$RUNDIR/escalation.md"
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

@test "ns report writes the golden timeline and prints the path" {
  run ns report sbx-12
  assert_success
  [ "$output" = "$RUNDIR/run-report.md" ]
  diff "$NS_REPO_ROOT/tests/fixtures/report/expected.md" "$RUNDIR/run-report.md"
}

@test "ns report reads the ledger from origin when the worktree is gone" {
  ns-ledger checkpoint "$RUNDIR/ledger.yaml" --push
  rm -rf "$SBX-sbx-12"
  run ns report sbx-12
  assert_success
  [ "$output" = "$NS_CONFIG_DIR/reports/sbx-12/run-report.md" ]
  grep -q '^# Run report: sbx-12$' "$output"
  grep -qF '| Wall time | 3h 21m |' "$output"
}

@test "ns report rejects an unknown run" {
  run ns report sbx-99
  assert_failure
}

@test "ns report ends planning at the first phase when there is no gate 1" {
  python3 - "$RUNDIR/ledger.yaml" <<'P'
import re, sys
p = sys.argv[1]
head, ev = open(p).read().split('events:\n', 1)
items = [i for i in re.split(r'(?m)^(?=- time:)', ev) if i.strip()]
items = [i for i in items if not re.search(r"type: (gate|approved)\n", i)]
open(p, 'w').write(head + 'events:\n' + ''.join(items))
P
  run ns report sbx-12
  assert_success
  grep -qF '| planning | 2026-10-02 10:00 | 1h 11m |' "$RUNDIR/run-report.md"
}

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
  test: "true"
git: {}
stacks: [python]
EOF
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T2 --yes >/dev/null
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  LEDGER="$WT/.nightshift/runs/sbx-12/ledger.yaml"
}

# ---- ns-x7 acceptance tests (RUN/test-strategy.md of ns-x7) ----

# x7_owner_events: the number of owner-note events in the ledger
x7_owner_events() { ns-ledger get "$LEDGER" '[.events[] | select(.type == "owner-note")] | length'; }

# x7_usage: the last run printed the ns note usage line and exited 2
x7_usage() {
  assert_failure 2
  assert_output_contains 'usage: ns note <id> "text"'
}

# AC-1: the note is appended with the pinned time, one owner-note event, committed and pushed
x7_note_appends() {
  local head
  head=$(git -C "$WT" rev-parse HEAD)
  [ "$(x7_owner_events)" = 0 ]
  NS_NOW=2026-10-07T21:04:00Z run ns note sbx-12 "use sqlite"
  assert_success
  [ "$output" = "note 1 sent to sbx-12; it is read at the next checkpoint" ]
  [ "$(ns-ledger get "$LEDGER" '.owner_notes | tostring')" = '[{"time":"2026-10-07T21:04:00Z","text":"use sqlite","read":false}]' ]
  [ "$(x7_owner_events)" = 1 ]
  [ "$(ns-ledger get "$LEDGER" '[.events[] | select(.type == "owner-note")][-1] | .time + " " + .note')" = "2026-10-07T21:04:00Z owner note 1 added" ]
  [ -z "$(git -C "$WT" status --porcelain -- .nightshift)" ]
  [ "$(git -C "$WT" rev-parse HEAD)" != "$head" ]
  git -C "$WT" fetch -q origin
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$WT" rev-parse origin/plan/sbx-12)" ]
}

@test "ns note appends a timestamped unread note, records owner-note, commits and pushes (ns-x7)" {
  x7_note_appends
}

# AC-1: a failed push is recorded as push-failed and ns note still exits 0
x7_note_push_fails() {
  git -C "$WT" remote set-url origin "$BATS_TEST_TMPDIR/nowhere.git"
  run ns note sbx-12 "x"
  assert_success
  [ "$(ns-ledger get "$LEDGER" '.owner_notes | length')" = 1 ]
  [ "$(ns-ledger get "$LEDGER" '.events[-1].type')" = push-failed ]
}

@test "ns note exits 0 and records push-failed when the push fails (ns-x7)" {
  x7_note_push_fails
}

# D1: quotes, backslashes, jq interpolation, $now and newlines are stored byte for byte
x7_note_safe_text() {
  local txt
  txt='a "b" \c \(.id) $now'$'\n''second line'
  run ns note sbx-12 "$txt"
  assert_success
  [ "$(ns-ledger get "$LEDGER" '.owner_notes[0].text')" = "$txt" ]
  [ "$(ns-ledger get "$LEDGER" '.owner_notes | length')" = 1 ]
}

@test "ns note stores quotes, backslashes, jq interpolation and newlines unchanged (ns-x7)" {
  x7_note_safe_text
}

# AC-2: bad arguments exit 2 with the usage line, an unknown id exits 1; the ledger is unchanged
x7_note_errors() {
  local head
  head=$(git -C "$WT" rev-parse HEAD)
  cp "$LEDGER" "$BATS_TEST_TMPDIR/before.yaml"
  run ns note sbx-12
  x7_usage
  run ns note sbx-12 ""
  x7_usage
  run ns note sbx-12 "   "
  x7_usage
  run ns note sbx-12 a b
  x7_usage
  run ns note -x a
  x7_usage
  run ns note sbx-99 "x"
  assert_failure 1
  assert_output_contains "unknown run sbx-99"
  cmp "$LEDGER" "$BATS_TEST_TMPDIR/before.yaml"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ]
  run ns note --help
  assert_success
  assert_output_contains 'usage: ns note <id> "text"'
}

@test "ns note rejects missing, empty or extra arguments and unknown runs without touching the ledger (ns-x7)" {
  x7_note_errors
}

# AC-5: with no unread notes owner-notes prints nothing and writes nothing; bad arguments exit 2
x7_owner_notes_empty() {
  local head
  run ns-conductor --help
  assert_output_contains "owner-notes   <id>"
  head=$(git -C "$WT" rev-parse HEAD)
  cp "$LEDGER" "$BATS_TEST_TMPDIR/before.yaml"
  run ns-conductor owner-notes sbx-12
  assert_success
  [ -z "$output" ]
  cmp "$LEDGER" "$BATS_TEST_TMPDIR/before.yaml"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ]
  run ns-conductor owner-notes
  assert_failure 2
  assert_output_contains "usage: ns-conductor owner-notes <id>"
}

@test "ns-conductor owner-notes with no notes prints nothing and changes nothing (ns-x7)" {
  x7_owner_notes_empty
}

# AC-5: unread notes are printed one per line (newlines folded), marked read, recorded and
# committed; a second call prints nothing; a later note is the only one printed next time
x7_owner_notes_read() {
  NS_NOW=2026-10-07T21:04:00Z ns note sbx-12 "use sqlite" >/dev/null
  NS_NOW=2026-10-07T21:05:00Z ns note sbx-12 $'line one\nline two' >/dev/null
  run ns-conductor owner-notes sbx-12
  assert_success
  [ "$output" = "owner note 2026-10-07T21:04:00Z: use sqlite"$'\n'"owner note 2026-10-07T21:05:00Z: line one line two" ]
  [ "$(ns-ledger get "$LEDGER" '[.owner_notes[].read] | tostring')" = '[true,true]' ]
  [ "$(ns-ledger get "$LEDGER" '.owner_notes[1].text')" = $'line one\nline two' ]
  [ "$(ns-ledger get "$LEDGER" '.events[-1] | .type + ":" + .note')" = "owner-note:read 2 note(s)" ]
  [ -z "$(git -C "$WT" status --porcelain -- .nightshift)" ]
  cp "$LEDGER" "$BATS_TEST_TMPDIR/before.yaml"
  run ns-conductor owner-notes sbx-12
  assert_success
  [ -z "$output" ]
  cmp "$LEDGER" "$BATS_TEST_TMPDIR/before.yaml"
  NS_NOW=2026-10-07T21:06:00Z ns note sbx-12 "third" >/dev/null
  run ns-conductor owner-notes sbx-12
  assert_success
  [ "$output" = "owner note 2026-10-07T21:06:00Z: third" ]
  [ "$(ns-ledger get "$LEDGER" '[.owner_notes[].read] | tostring')" = '[true,true,true]' ]
  [ "$(ns-ledger get "$LEDGER" '.events[-1] | .type + ":" + .note')" = "owner-note:read 1 note(s)" ]
}

@test "ns-conductor owner-notes prints unread notes, marks exactly those read and prints nothing the second time (ns-x7)" {
  x7_owner_notes_read
}

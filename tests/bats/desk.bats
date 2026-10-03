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
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T1 --yes >/dev/null
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  LEDGER="$WT/.nightshift/runs/sbx-12/ledger.yaml"
  RUNDIR="$WT/.nightshift/runs/sbx-12"
  DESK="$NS_DESK_DIR/nightshift-sandbox"
  printf '# Plan\n\nDo the thing.\n' >"$RUNDIR/plan.md"
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

tok() { printf 'ghp_%s' "abcdefghijklmnopqrstuvwxyz0123456789"; }

@test "publishing copies the file with mode 0640, records .published and index.md" {
  run ns publish sbx-12 RUN/plan.md:plan.md
  assert_success
  f="$DESK/runs/sbx-12/plan.md"
  [ "$(stat -c %a "$f")" = 640 ]
  cmp "$f" "$RUNDIR/plan.md"
  sum=$(sha256sum "$f" | awk '{print $1}')
  printf 'plan.md\t.nightshift/runs/sbx-12/plan.md\t%s\n' "$sum" >"$BATS_TEST_TMPDIR/want"
  cmp "$DESK/runs/sbx-12/.published" "$BATS_TEST_TMPDIR/want"
  grep -q '^# nightshift-sandbox runs$' "$DESK/index.md"
  grep -q '^Updated 2026-10-02T21:00:00Z by ns publish\.$' "$DESK/index.md"
  grep -qF '| sbx-12 | T1 | ' "$DESK/index.md"
  grep -qF '[plan.md](runs/sbx-12/plan.md) |' "$DESK/index.md"
}

@test "republishing replaces the line and keeps the others" {
  printf 'a: 1\n' >"$RUNDIR/other.yaml"
  ns publish sbx-12 RUN/plan.md RUN/other.yaml
  printf '# Plan 2\n' >"$RUNDIR/plan.md"
  run ns publish sbx-12 RUN/plan.md
  assert_success
  [ "$(grep -c '^plan.md' "$DESK/runs/sbx-12/.published")" = 1 ]
  [ "$(wc -l <"$DESK/runs/sbx-12/.published")" = 2 ]
  sum=$(sha256sum "$DESK/runs/sbx-12/plan.md" | awk '{print $1}')
  grep -q "^plan.md.*$sum\$" "$DESK/runs/sbx-12/.published"
  grep -qF '[other.yaml](runs/sbx-12/other.yaml)' "$DESK/index.md"
}

@test "HTML with an external script is refused" {
  printf '<html><script src="https://x"></script></html>\n' >"$RUNDIR/r.html"
  run ns publish sbx-12 RUN/r.html
  assert_failure 1
  assert_output_contains "r.html: HTML must be self-contained (no external scripts or styles)"
  [ ! -e "$DESK/runs/sbx-12/r.html" ]
}

@test "HTML with an external stylesheet or @import is refused" {
  printf '<link rel="stylesheet" href="https://x/a.css">\n' >"$RUNDIR/a.html"
  run ns publish sbx-12 RUN/a.html
  assert_failure 1
  printf '<style>@import url(x.css);</style>\n' >"$RUNDIR/b.html"
  run ns publish sbx-12 RUN/b.html
  assert_failure 1
}

@test "HTML with an inline style only is published" {
  printf '<html><style>p{color:red}</style><p>hi</p></html>\n' >"$RUNDIR/r.html"
  run ns publish sbx-12 RUN/r.html
  assert_success
  [ -f "$DESK/runs/sbx-12/r.html" ]
}

@test "a file containing a token is refused" {
  printf 'key %s\n' "$(tok)" >"$RUNDIR/plan.md"
  run ns publish sbx-12 RUN/plan.md
  assert_failure 1
  assert_output_contains "plan.md: looks like it contains a token; not published"
  [ ! -e "$DESK/runs/sbx-12/plan.md" ]
}

@test "a bad name is refused" {
  run ns publish sbx-12 "RUN/plan.md:bad name.md"
  assert_failure 1
  [ ! -e "$DESK/runs/sbx-12/bad name.md" ]
}

@test "a path outside the worktree is refused" {
  printf 'x\n' >"$BATS_TEST_TMPDIR/outside.md"
  run ns publish sbx-12 "$BATS_TEST_TMPDIR/outside.md"
  assert_failure 1
  run ns publish sbx-12 RUN/../../../../outside.md
  assert_failure 1
}

@test "ns-github.env is accepted as a name" {
  printf 'REQUIRED_CHECKS=ci\n' >"$RUNDIR/x.txt"
  run ns publish sbx-12 RUN/x.txt:ns-github.env
  assert_success
  [ -f "$DESK/runs/sbx-12/ns-github.env" ]
}

@test "a missing desk root fails" {
  rm -rf "$NS_DESK_DIR"
  run ns publish sbx-12 RUN/plan.md
  assert_failure 1
  assert_output_contains "desk $NS_DESK_DIR not found: run bootstrap.sh or set NS_DESK_DIR"
}

@test "publishing at a gate notifies with the desk URL" {
  export NS_NTFY_TOPIC=topic1 NS_DESK_URL=https://desk.example
  ns-ledger state "$LEDGER" waiting --gate 1
  run ns publish sbx-12 RUN/plan.md
  assert_success
  grep -qF 'Click: https://desk.example/nightshift-sandbox/runs/sbx-12/plan.md' "$NS_STUB_LOG"
  grep -qF 'sbx-12: gate 1 needs you' "$NS_STUB_LOG"
  grep -qF 'https://ntfy.sh/topic1' "$NS_STUB_LOG"
}

@test "publishing without a gate says how many documents" {
  export NS_NTFY_TOPIC=topic1
  run ns publish sbx-12 RUN/plan.md
  assert_success
  grep -qF 'sbx-12: 1 document(s) published' "$NS_STUB_LOG"
  ! grep -q 'Click:' "$NS_STUB_LOG"
}

@test "ns-notify without a topic exits 0 and sends nothing" {
  run ns-notify "hello"
  assert_success
  assert_output_contains "ns-notify: NS_NTFY_TOPIC is not set; not sent"
  ! grep -q '^curl' "$NS_STUB_LOG"
}

@test "ns-notify with the wrong argument count is a usage error" {
  run ns-notify
  assert_failure 2
}

@test "ns-notify refuses a token in the text" {
  export NS_NTFY_TOPIC=topic1
  run ns-notify "oops $(tok)"
  assert_failure 1
  assert_output_contains "ns-notify: refusing to send something that looks like a token"
  ! grep -q '^curl' "$NS_STUB_LOG"
}

@test "ns-notify cuts the text to 200 characters" {
  export NS_NTFY_TOPIC=topic1
  long=$(printf 'a%.0s' $(seq 1 300))
  run ns-notify "$long"
  assert_success
  grep -qE -- "-d a{200} " "$NS_STUB_LOG"
  ! grep -qE -- "a{201}" "$NS_STUB_LOG"
}

@test "ns-notify fails when curl fails" {
  export NS_NTFY_TOPIC=topic1 CURL_STUB_EXIT=7
  run ns-notify "hello"
  assert_failure 1
  assert_output_contains "ns-notify: could not reach ntfy"
}

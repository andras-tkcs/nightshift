#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  BARE="$BATS_TEST_TMPDIR/origin.git"
  REPO="$BATS_TEST_TMPDIR/repo"
  PROFILE="$REPO/.claude/project-profile.yaml"
  git init -q --bare -b main "$BARE"
  git init -q -b main "$REPO"
  mkdir -p "$REPO/.claude"
  cat >"$PROFILE" <<'YAML'
project: tagtest
prefix: tag
commands:
  setup: "true"
  test: "true"
git: {}
stacks: [python]
YAML
  printf '# tagtest\n' >"$REPO/README.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "Initial commit"
  git -C "$REPO" remote add origin "$BARE"
  git -C "$REPO" push -q origin main
  git -C "$REPO" tag -a v0.1.0 -m "Release v0.1.0"
  git -C "$REPO" push -q origin v0.1.0
  # a merged PR since the last tag
  git -C "$REPO" checkout -q -b feature/x
  printf 'x\n' >"$REPO/x.txt"
  git -C "$REPO" add x.txt
  git -C "$REPO" commit -q -m "add x"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge -q --no-ff feature/x -m "Merge pull request #7 from o/feature/x

Add the x feature"
  git -C "$REPO" push -q origin main
}

@test "ns tag help is available" {
  run ns tag --help
  assert_success
  assert_output_contains "ns tag"
}

@test "ns tag refuses when local main is dirty" {
  printf 'dirty\n' >>"$REPO/README.md"
  run ns tag v0.1.1 --repo "$REPO" --yes
  assert_failure 1
  assert_output_contains "dirty"
  run git -C "$BARE" tag -l v0.1.1
  [ -z "$output" ]
}

@test "ns tag refuses when local main differs from origin/main" {
  printf 'y\n' >"$REPO/y.txt"
  git -C "$REPO" add y.txt
  git -C "$REPO" commit -q -m "local only"
  run ns tag v0.1.1 --repo "$REPO" --yes
  assert_failure 1
  assert_output_contains "origin"
  run git -C "$BARE" tag -l v0.1.1
  [ -z "$output" ]
}

@test "ns tag refuses a bad tag name" {
  run ns tag 1.2 --repo "$REPO" --yes
  assert_failure 1
  assert_output_contains "vX.Y.Z"
  run ns tag v1.2 --repo "$REPO" --yes
  assert_failure 1
}

@test "ns tag refuses a tag that already exists" {
  run ns tag v0.1.0 --repo "$REPO" --yes
  assert_failure 1
  assert_output_contains "exists"
}

@test "ns tag refuses a tag that exists only on origin" {
  git -C "$REPO" tag -d v0.1.0 >/dev/null
  run ns tag v0.1.0 --repo "$REPO" --yes
  assert_failure 1
  assert_output_contains "exists"
}

@test "ns tag refuses a version that is not the next step" {
  run ns tag v0.3.0 --repo "$REPO" --yes
  assert_failure 1
  assert_output_contains "next"
  run ns tag v2.0.0 --repo "$REPO" --yes
  assert_failure 1
  run git -C "$BARE" tag -l
  [ "$output" = "v0.1.0" ]
}

@test "ns tag refuses when the project checks fail" {
  sed -i 's/test: "true"/test: "false"/' "$PROFILE"
  git -C "$REPO" commit -q -am "failing checks"
  git -C "$REPO" push -q origin main
  run ns tag v0.1.1 --repo "$REPO" --yes
  assert_failure 1
  assert_output_contains "checks"
  run git -C "$BARE" tag -l v0.1.1
  [ -z "$output" ]
}

@test "ns tag tags, pushes, records PR titles and prints the upgrade command" {
  run ns tag v0.1.1 --repo "$REPO" --yes
  assert_success
  assert_output_contains "/opt/nightshift/current/bin/bootstrap.sh --upgrade v0.1.1"
  run git -C "$BARE" tag -l v0.1.1
  [ "$output" = "v0.1.1" ]
  run git -C "$BARE" tag -l --format='%(contents)' v0.1.1
  assert_output_contains "Release v0.1.1"
  assert_output_contains "Add the x feature"
}

@test "ns tag also records squash-merged PR titles, and not plain commits (#81)" {
  printf 'y\n' >"$REPO/y.txt"
  git -C "$REPO" add y.txt
  git -C "$REPO" commit -q -m "Add the y feature (#9)"
  printf 'z\n' >"$REPO/z.txt"
  git -C "$REPO" add z.txt
  git -C "$REPO" commit -q -m "Fix a typo"
  git -C "$REPO" push -q origin main
  run ns tag v0.1.1 --repo "$REPO" --yes
  assert_success
  run git -C "$BARE" tag -l --format='%(contents)' v0.1.1
  assert_output_contains "- Add the x feature"
  assert_output_contains "- Add the y feature (#9)"
  [[ $output != *"Fix a typo"* ]]
}

@test "ns tag warns, but still tags, when CI is not green" {
  mkdir -p "$BATS_TEST_TMPDIR/ghbin"
  cat >"$BATS_TEST_TMPDIR/ghbin/gh" <<'EOF'
#!/usr/bin/env bash
echo '[{"status":"completed","conclusion":"failure"}]'
EOF
  chmod +x "$BATS_TEST_TMPDIR/ghbin/gh"
  PATH="$BATS_TEST_TMPDIR/ghbin:$PATH" run ns tag v0.1.1 --repo "$REPO" --yes
  assert_success
  assert_output_contains "warning"
  assert_output_contains "CI"
  run git -C "$BARE" tag -l v0.1.1
  [ "$output" = "v0.1.1" ]
}

@test "ns tag refuses a tag that exists only on origin (ls-remote path)" {
  # hide the tag from fetch --tags so only the ls-remote check can catch it
  git -C "$REPO" tag -d v0.1.0 >/dev/null
  git -C "$BARE" tag v0.1.2
  mkdir -p "$BATS_TEST_TMPDIR/gitbin"
  cat >"$BATS_TEST_TMPDIR/gitbin/git" <<'EOF2'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  [ "$a" = "--tags" ] && continue
  args+=("$a")
done
exec /usr/bin/git "${args[@]}"
EOF2
  chmod +x "$BATS_TEST_TMPDIR/gitbin/git"
  PATH="$BATS_TEST_TMPDIR/gitbin:$PATH" run ns tag v0.1.2 --repo "$REPO" --yes
  assert_failure 1
  assert_output_contains "exists"
}

@test "ns tag warns, but still tags, when gh is missing" {
  mkdir -p "$BATS_TEST_TMPDIR/nogh"
  local c p
  for c in bash env git jq sort tail grep awk sed cat dirname basename mktemp rm mkdir tr head date uname readlink tmux flock; do
    p=$(command -v "$c" 2>/dev/null) || continue
    ln -sf "$p" "$BATS_TEST_TMPDIR/nogh/$c"
  done
  PATH="$BATS_TEST_TMPDIR/nogh" run "$NS_REPO_ROOT/bin/ns" tag v0.1.1 --repo "$REPO" --yes
  assert_success
  assert_output_contains "gh is missing"
  run git -C "$BARE" tag -l v0.1.1
  [ "$output" = "v0.1.1" ]
}

# live_run <id>: register a project and a running run with a live tmux session.
live_run() {
  local fix="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$fix/.claude"
  cp "$PROFILE" "$fix/.claude/"
  printf '# sandbox\n' >"$fix/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$fix"
  ns project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  export TMUX_STUB_PANE_PID=$$
  ns new "$1" --tier T1 --yes >&2
  ns-ledger set "$(ls "$NS_CODING_DIR"/worktrees/*-"$1"/.nightshift/runs/"$1"/ledger.yaml)" '.state="running"'
  mkdir -p "$NS_CONFIG_DIR/logs/$1"
  : >"$NS_CONFIG_DIR/logs/$1/conductor.jsonl"
}

@test "ns tag warns about active Nightshift runs, but still tags" {
  live_run sbx-12
  run ns tag v0.1.1 --repo "$REPO" --yes
  assert_success
  assert_output_contains "runs are active"
  assert_output_contains "sbx-12"
  assert_output_contains "--upgrade"
  run git -C "$BARE" tag -l v0.1.1
  [ "$output" = "v0.1.1" ]
}

@test "ns tag prints no active-runs warning when no run is active" {
  run ns tag v0.1.1 --repo "$REPO" --yes
  assert_success
  [[ "$output" != *"runs are active"* ]]
}

@test "ns tag accepts the next version with leading zeros" {
  git -C "$REPO" tag -a v0.1.08 -m x
  git -C "$REPO" push -q origin v0.1.08
  run ns tag v0.1.10 --repo "$REPO" --yes
  assert_failure 1
  assert_output_contains "next"
  run ns tag v0.1.09 --repo "$REPO" --yes
  assert_success
}

@test "ns tag removes the local tag when the push fails" {
  printf '#!/bin/sh\nexit 1\n' >"$BARE/hooks/pre-receive"
  chmod +x "$BARE/hooks/pre-receive"
  run ns tag v0.1.1 --repo "$REPO" --yes
  assert_failure 1
  assert_output_contains "push"
  run git -C "$REPO" tag -l v0.1.1
  [ -z "$output" ]
}

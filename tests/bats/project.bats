#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
  FIX="$BATS_TEST_TMPDIR/fixture"
  mk_tree "$FIX" ""
  make_remote acme/widget "$FIX"
}

# mk_tree <dir> <extra yaml line>
mk_tree() {
  mkdir -p "$1/.claude"
  cat >"$1/.claude/project-profile.yaml" <<EOF
project: widget
prefix: wd
commands:
  setup: touch "\$NS_CONFIG_DIR/setup-ran"
git: {}
stacks: [python]
EOF
  if [ -n "$2" ]; then printf '%s\n' "$2" >>"$1/.claude/project-profile.yaml"; fi
  printf '# widget\n' >"$1/README.md"
}

ns() { "$NS_REPO_ROOT/bin/ns" "$@"; }

@test "happy path: clone, setup, desk, registry" {
  run ns project add acme/widget --prefix wd
  assert_success
  assert_output_contains "added acme/widget as wd at $NS_CODING_DIR/widget"
  [ -d "$NS_CODING_DIR/widget/.git" ]
  [ -f "$NS_CONFIG_DIR/setup-ran" ]
  run bash -c "ls -d '$NS_CODING_DIR'/worktrees/*-profilecheck 2>/dev/null"
  [ -z "$output" ]
  [ -d "$NS_DESK_DIR/widget/runs" ]
  run jq -r '.projects[0] | "\(.name) \(.repo) \(.prefix) \(.sandbox)"' < <(python3 "$NS_REPO_ROOT/bin/lib/nsyaml.py" to-json "$NS_CONFIG_DIR/projects.yaml")
  [ "$output" = "widget acme/widget wd false" ]
  run ns project add acme/widget --prefix wd
  assert_success
  assert_output_contains "already registered: acme/widget (prefix wd)"
}

@test "an existing clone with the matching origin is adopted untouched" {
  git clone -q "$GH_STUB_REMOTES/acme/widget.git" "$NS_CODING_DIR/widget"
  git -C "$NS_CODING_DIR/widget" switch -q -c scratch
  printf 'dirty\n' >>"$NS_CODING_DIR/widget/README.md"
  head_before=$(git -C "$NS_CODING_DIR/widget" rev-parse HEAD)
  branch_before=$(git -C "$NS_CODING_DIR/widget" branch --show-current)
  status_before=$(git -C "$NS_CODING_DIR/widget" status --porcelain)
  run ns project add acme/widget --prefix wd
  assert_success
  [ "$(git -C "$NS_CODING_DIR/widget" rev-parse HEAD)" = "$head_before" ]
  [ "$(git -C "$NS_CODING_DIR/widget" branch --show-current)" = "$branch_before" ]
  [ "$(git -C "$NS_CODING_DIR/widget" status --porcelain)" = "$status_before" ]
  run grep -c 'repo clone' "$GH_STUB_LOG"
  [ "$output" = 0 ]
  [ -f "$NS_CONFIG_DIR/setup-ran" ]
}

@test "an existing path with another origin fails" {
  make_remote other/widget
  git clone -q "$GH_STUB_REMOTES/other/widget.git" "$NS_CODING_DIR/widget"
  run ns project add acme/widget --prefix wd
  assert_failure 1
  assert_output_contains "exists and is not a clone of acme/widget"
}

@test "same repo with another prefix fails" {
  ns project add acme/widget --prefix wd
  run ns project add acme/widget --prefix zz
  assert_failure 1
  assert_output_contains "acme/widget is already registered with prefix wd"
}

@test "prefix used by another repo fails" {
  make_remote acme/gadget "$FIX"
  ns project add acme/widget --prefix wd
  run ns project add acme/gadget --prefix wd
  assert_failure 1
  assert_output_contains "prefix wd is used by acme/widget"
}

@test "bad prefix and bad repo are usage errors" {
  run ns project add acme/widget --prefix Bad
  assert_failure 2
  run ns project add widget --prefix wd
  assert_failure 2
  run ns project add acme/widget
  assert_failure 2
}

@test "a profile with an unknown key fails and registers nothing" {
  bad="$BATS_TEST_TMPDIR/badfix"
  mk_tree "$bad" "bogus_key: 1"
  make_remote acme/broken "$bad"
  run ns project add acme/broken --prefix br
  assert_failure 1
  [ ! -f "$NS_CONFIG_DIR/projects.yaml" ]
  run bash -c "ls -d '$NS_CODING_DIR'/worktrees/*-profilecheck 2>/dev/null"
  [ -z "$output" ]
}

@test "--branch reads the profile from that branch and leaves the checkout alone" {
  work="$BATS_TEST_TMPDIR/work"
  git clone -q "$GH_STUB_REMOTES/acme/widget.git" "$work"
  git -C "$work" switch -q -c e2e/x
  printf 'project: widget\nprefix: wd\ncommands:\n  setup: touch "$NS_CONFIG_DIR/setup-branch"\ngit: {}\nstacks: [python]\n' \
    >"$work/.claude/project-profile.yaml"
  git -C "$work" commit -q -am "branch profile"
  git -C "$work" push -q origin e2e/x
  run ns project add acme/widget --prefix wd --branch e2e/x
  assert_success
  [ -f "$NS_CONFIG_DIR/setup-branch" ]
  [ ! -f "$NS_CONFIG_DIR/setup-ran" ]
  [ "$(git -C "$NS_CODING_DIR/widget" branch --show-current)" = main ]
  run jq -r '.projects[0].branch' < <(python3 "$NS_REPO_ROOT/bin/lib/nsyaml.py" to-json "$NS_CONFIG_DIR/projects.yaml")
  [ "$output" = e2e/x ]
}

@test "--sandbox is stored as true" {
  run ns project add acme/widget --prefix wd --sandbox
  assert_success
  run jq -r '.projects[0].sandbox' < <(python3 "$NS_REPO_ROOT/bin/lib/nsyaml.py" to-json "$NS_CONFIG_DIR/projects.yaml")
  [ "$output" = true ]
}

@test "token file with mode 644 fails" {
  mkdir -p "$NS_CONFIG_DIR/tokens"
  printf 'github_pat_%s\n' "AAAAAAAAAAAAAAAAAAAAAAAAAAAA" >"$NS_CONFIG_DIR/tokens/acme"
  chmod 644 "$NS_CONFIG_DIR/tokens/acme"
  run ns project add acme/widget --prefix wd
  assert_failure 1
  assert_output_contains "must be mode 600"
  refute_token_in "$BATS_TEST_TMPDIR/gh.log"
  case "$output" in *AAAAAAAAAAAAAAAA*) false ;; esac
}

@test "token file with mode 600 is used and never printed" {
  mkdir -p "$NS_CONFIG_DIR/tokens"
  printf 'github_pat_%s\n' "AAAAAAAAAAAAAAAAAAAAAAAAAAAA" >"$NS_CONFIG_DIR/tokens/acme"
  chmod 600 "$NS_CONFIG_DIR/tokens/acme"
  run ns project add acme/widget --prefix wd
  assert_success
  run grep 'repo clone' "$GH_STUB_LOG"
  [[ $output == *"[token]" ]]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/out.txt"
  refute_token_in "$GH_STUB_LOG" "$NS_CONFIG_DIR/projects.yaml" "$BATS_TEST_TMPDIR/out.txt"
}

@test "a repo without a profile prints the onboarding hint and registers" {
  make_remote acme/bare
  run ns project add acme/bare --prefix bare
  assert_success
  assert_output_contains "no .claude/project-profile.yaml on main: start onboarding with ns new bare-onboard --onboard"
  assert_output_contains "added acme/bare as bare"
  [ -d "$NS_DESK_DIR/bare/runs" ]
}

@test "missing desk root fails" {
  rm -rf "$NS_DESK_DIR"
  run ns project add acme/widget --prefix wd
  assert_failure 1
  assert_output_contains "desk $NS_DESK_DIR not found: run bootstrap.sh or set NS_DESK_DIR"
}

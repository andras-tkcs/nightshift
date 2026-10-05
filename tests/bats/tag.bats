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

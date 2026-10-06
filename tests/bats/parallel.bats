load helpers

setup() { ns_test_setup; }

@test "CI installs parallel and runs bats with --jobs" {
  run grep -E 'apt-get install.* parallel( |$)' "$NS_REPO_ROOT/.github/workflows/ci.yml"
  assert_success
  run grep -E 'bats --jobs ' "$NS_REPO_ROOT/.github/workflows/ci.yml"
  assert_success
}

@test "CLAUDE.md documents the parallel bats command and the parallel dependency" {
  run grep -F 'bats --jobs "$(nproc)" tests/bats' "$NS_REPO_ROOT/CLAUDE.md"
  assert_success
  run grep -iE 'GNU parallel|`parallel`' "$NS_REPO_ROOT/CLAUDE.md"
  assert_success
}

@test "docs/development.md documents bats --jobs" {
  run grep -F 'bats --jobs' "$NS_REPO_ROOT/docs/development.md"
  assert_success
}

@test "bats tests do not match processes by name (parallel safety)" {
  run grep -nE '\b(pkill|killall)\b' "$NS_REPO_ROOT"/tests/bats/*.bats "$NS_REPO_ROOT"/tests/bats/helpers.bash --exclude=parallel.bats --exclude=e2e-harness.bats
  assert_failure
}

@test "no call site runs the bats suite serially (issue #116)" {
  local f
  for f in .claude/project-profile.yaml bin/lib/ns-tag.sh .claude/agents/final-reviewer.md .claude/commands/implement-local.md CLAUDE.md docs/development.md docs/usage.md; do
    run grep -nE '(^|[^-])bats tests/bats' "$NS_REPO_ROOT/$f"
    [ "$status" -ne 0 ] || {
      echo "serial bats in $f: $output"
      return 1
    }
    run grep -F 'bats --jobs "$(nproc)" tests/bats' "$NS_REPO_ROOT/$f"
    [ "$status" -eq 0 ] || {
      echo "no parallel bats form in $f"
      return 1
    }
  done
}

@test "CLAUDE.md, README.md and docs state no 4 GB limit except as minimum or history (issue #116)" {
  run grep -rnE '4 ?GB' "$NS_REPO_ROOT/CLAUDE.md" "$NS_REPO_ROOT/README.md" "$NS_REPO_ROOT/docs" "$NS_REPO_ROOT/.claude" "$NS_REPO_ROOT/bin"
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qiE 'minimum|original|swap|sized for|CX23|history|was |made three' <<<"$line" || {
      echo "unexplained 4 GB: $line"
      return 1
    }
  done <<<"$output"
}

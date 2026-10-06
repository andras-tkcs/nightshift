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
  for f in .claude/project-profile.yaml bin/lib/ns-tag.sh .claude/agents/final-reviewer.md .claude/commands/implement-local.md CLAUDE.md docs/development.md docs/usage.md docs/architecture.html; do
    # ns-tag.sh keeps a serial fallback for hosts without GNU parallel (tested in tag.bats)
    [ "$f" = bin/lib/ns-tag.sh ] || run grep -nE '(^|[^-])bats tests/bats([^/]|$)' "$NS_REPO_ROOT/$f"
    [ "$f" != bin/lib/ns-tag.sh ] || status=1
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
  cd "$NS_REPO_ROOT"
  run grep -rnE '4 ?GB' CLAUDE.md README.md docs .claude bin
  local line text
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    text=${line#*:*:}
    # allowed: the stated minimum, the original sizing, the swap, and the throwaway lab server
    grep -qE '4 GB RAM (is the minimum|and 40 GB disk at minimum)|code default is 2, which fits the 4 GB minimum|[Oo]riginal sizing|sized for 4 GB|GB (of )?swap|swap as a safety net|4 GB RAM or more \(the minimum|ns-lab|CX23 · 2 vCPU · 4 GB|made three simultaneous runs risky' <<<"$text" || {
      echo "unexplained 4 GB: $line"
      return 1
    }
  done <<<"$output"
}

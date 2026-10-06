# shellcheck shell=bash
# Read a project's profile from git. Source this file; it defines functions only.

# ns_profile_json <repo-dir> [<prefix> [<branch>]]
# Prints the resolved profile as JSON. Returns 3 (with defaults printed) when the
# ref has no profile. Never reads the working tree.
ns_profile_json() {
  local dir="$1" prefix="${2:-x}" branch="${3:-}" tmp rc=0
  if [ -z "$branch" ]; then
    branch=$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || branch=origin/main
    branch=${branch#origin/}
  fi
  git -C "$dir" fetch -q origin "$branch" 2>/dev/null || true
  if git -C "$dir" cat-file -e "origin/$branch:.claude/project-profile.yaml" 2>/dev/null; then
    tmp=$(mktemp)
    git -C "$dir" show "origin/$branch:.claude/project-profile.yaml" >"$tmp"
    python3 "$NS_HOME/bin/lib/profile.py" show "$tmp" || rc=$?
    rm -f "$tmp"
    return "$rc"
  fi
  python3 "$NS_HOME/bin/lib/profile.py" defaults |
    jq -c --arg b "$branch" --arg p "$(basename "$(cd "$dir" && pwd)")" --arg x "$prefix" \
      '.git.base_branch = $b | .project = $p | .prefix = $x | .stacks = [] | .checks = []'
  return 3
}

# ns_profile_checks_run <dir> <profile json> <log file>: run the profile's checks in <dir> in a clean
# environment, one line per check on stdout (PASS|SKIP|FAIL <stack> <name>), their output to the log.
# A python test (or any pytest command) exiting 5 collected no tests: SKIP. Without checks it prints
# "SKIP no checks configured". Returns 1 when a check failed, else 0.
ns_profile_checks_run() {
  local dir="$1" prof="$2" log="$3" n total stack name cmd crc failed=0
  total=$(jq '(.checks // []) | length' <<<"$prof")
  if [ "$total" -eq 0 ]; then
    printf 'SKIP no checks configured\n'
    return 0
  fi
  : >"$log"
  for ((n = 0; n < total; n++)); do
    stack=$(jq -r ".checks[$n].stack" <<<"$prof")
    name=$(jq -r ".checks[$n].name" <<<"$prof")
    cmd=$(jq -r ".checks[$n].cmd" <<<"$prof")
    printf '== %s %s: %s\n' "$stack" "$name" "$cmd" >>"$log"
    crc=0
    (cd "$dir" && env -i HOME="${HOME:-}" PATH="$PATH" LANG="${LANG:-C.UTF-8}" TERM="${TERM:-dumb}" \
      TMPDIR="${TMPDIR:-/tmp}" bash -c "$cmd") >>"$log" 2>&1 </dev/null || crc=$?
    if [ "$crc" -eq 0 ]; then
      printf 'PASS %s %s\n' "$stack" "$name"
    elif [ "$crc" -eq 5 ] && { { [ "$stack" = python ] && [ "$name" = test ]; } || [[ $cmd == *pytest* ]]; }; then
      printf 'SKIP %s %s\n' "$stack" "$name"
    else
      printf 'FAIL %s %s\n' "$stack" "$name"
      failed=1
    fi
  done
  return "$failed"
}

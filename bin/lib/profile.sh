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

# shellcheck shell=bash
# summary: tag a release on main after safety checks (owner only)

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/profile.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

ns_tag_help() {
  printf 'usage: ns tag <vX.Y.Z> [--repo <dir>] [--yes]\n\n'
  printf 'Tag the base branch of a repository as a release and push the tag. Refuses when\n'
  printf 'the local branch is dirty or differs from origin, the name is not vX.Y.Z or is not\n'
  printf 'the next version, the tag exists, CHANGELOG.md still has [Unreleased] entries or no\n'
  printf 'section for the version, or the project checks fail. Warns when CI is not\n'
  printf 'green or Nightshift runs are active (the upgrade refuses while they are). Prints the\n'
  printf 'root upgrade command. --yes skips the confirmation. Owner only.\n'
}

# ns_tag_next_ok <tag> <last>: succeeds when <tag> is the next step after <last>
ns_tag_next_ok() {
  local t="${1#v}" l="${2#v}" tm tn tp lm ln lp
  IFS=. read -r tm tn tp <<<"$t"
  IFS=. read -r lm ln lp <<<"$l"
  tm=$((10#$tm)) tn=$((10#$tn)) tp=$((10#$tp)) lm=$((10#$lm)) ln=$((10#$ln)) lp=$((10#$lp))
  [ "$tm" = "$lm" ] && [ "$tn" = "$ln" ] && [ "$tp" = "$((lp + 1))" ] && return 0
  [ "$tm" = "$lm" ] && [ "$tn" = "$((ln + 1))" ] && [ "$tp" = 0 ] && return 0
  [ "$tm" = "$((lm + 1))" ] && [ "$tn" = 0 ] && [ "$tp" = 0 ] && return 0
  return 1
}

# ns_tag_warn_active_runs: one warning listing runs that are running and not dead
ns_tag_warn_active_runs() {
  local entry id wt led state gate rel health lines=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    id=$(jq -r .id <<<"$entry")
    wt=$(jq -r .worktree <<<"$entry")
    [ -f "$wt/.nightshift/runs/$id/ledger.yaml" ] || continue
    led=$("$NS_HOME/bin/ns-ledger" get "$wt/.nightshift/runs/$id/ledger.yaml" 2>/dev/null) || continue
    state=$(jq -r '.state // ""' <<<"$led")
    [ "$state" = running ] || continue
    gate=$(jq -r '.gate // ""' <<<"$led")
    health=$(ns_run_health "$id" "$state" "$gate")
    [ "$health" != dead ] || continue
    rel=$(jq -r 'if (.release // "") == "" then "-" else .release end' <<<"$led")
    lines+=$(printf '\n  %s  %s  %s' "$id" "$state" "$rel")
  done < <(ns_runs_json | jq -c '.[] | select(.archived | not)' 2>/dev/null || true)
  [ -z "$lines" ] ||
    ns_warn "Nightshift runs are active (bootstrap.sh --upgrade refuses while they run):$lines"
}

# ns_tag_changelog_ok <repo> <tag>: dies unless CHANGELOG.md (when the repository has one) has an
# empty [Unreleased] section and a section for the version (issue #88)
# The file is read from the commit being tagged. Empty "###" sub-headings and HTML comments under
# [Unreleased] do not count as entries.
ns_tag_changelog_ok() {
  local text ver="${2#v}"
  text=$(git -C "$1" show HEAD:CHANGELOG.md 2>/dev/null) || return 0
  if awk '/^## \[/ {inside = ($0 ~ /^## \[Unreleased\]/); next}
      inside && /[^[:space:]]/ && !/^###/ && !/^[[:space:]]*<!--.*-->[[:space:]]*$/ {found = 1}
      END {exit !found}' <<<"$text"; then
    ns_die "CHANGELOG.md: [Unreleased] still has entries: move them to '## [$ver] - <date>' in the release pull request (docs/development.md, Releasing)"
  fi
  awk -v h="## [$ver]" 'index($0, h) == 1 {f = 1} END {exit !f}' <<<"$text" ||
    ns_die "CHANGELOG.md has no ## [$ver] section: add a '## [$ver] - <date>' section in the release pull request (docs/development.md, Releasing)"
}

ns_tag_main() {
  local u="ns tag <vX.Y.Z> [--repo <dir>] [--yes]"
  local tag="" repo="" yes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        [ $# -ge 2 ] || ns_usage "$u"
        repo="$2"
        shift 2
        ;;
      --yes)
        yes=1
        shift
        ;;
      -*) ns_usage "$u" ;;
      *)
        [ -z "$tag" ] || ns_usage "$u"
        tag="$1"
        shift
        ;;
    esac
  done
  [ -n "$tag" ] || ns_usage "$u"
  if [ -z "$repo" ]; then
    repo=$(git rev-parse --show-toplevel 2>/dev/null) || ns_die "not in a git repository (use --repo)"
  fi
  [ -d "$repo" ] || ns_die "no such directory: $repo"
  repo=$(cd "$repo" && pwd)

  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || ns_die "tag name must look like vX.Y.Z: $tag"

  local profile base
  profile=$(ns_profile_json "$repo" 2>/dev/null) || true
  base=$(jq -r '.git.base_branch // "main"' <<<"$profile" 2>/dev/null) || base=main
  [ -n "$base" ] || base=main

  git -C "$repo" fetch -q origin "$base" --tags 2>/dev/null || ns_die "cannot fetch origin"
  [ "$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)" = "$base" ] ||
    ns_die "$repo is not on $base"
  [ -z "$(git -C "$repo" status --porcelain)" ] || ns_die "local $base is dirty: commit or discard changes"
  [ "$(git -C "$repo" rev-parse HEAD)" = "$(git -C "$repo" rev-parse "origin/$base")" ] ||
    ns_die "local $base differs from origin/$base: push or pull first"

  if git -C "$repo" rev-parse -q --verify "refs/tags/$tag" >/dev/null ||
    [ -n "$(git -C "$repo" ls-remote --tags origin "refs/tags/$tag")" ]; then
    ns_die "tag $tag exists"
  fi

  local last
  last=$(git -C "$repo" tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1) || last=""
  if [ -n "$last" ] && ! ns_tag_next_ok "$tag" "$last"; then
    ns_die "$tag is not the next version after $last (expected next patch, minor or major)"
  fi

  ns_tag_changelog_ok "$repo" "$tag"

  local cmd
  cmd=$(jq -r '.commands.test // ""' <<<"$profile" 2>/dev/null) || cmd=""
  printf 'running project checks...\n'
  if [ -n "$cmd" ]; then
    (cd "$repo" && bash -c "$cmd") >&2 || ns_die "project checks failed: not tagging"
  else
    # parallel bats needs GNU parallel; without it the suite runs serially
    (cd "$repo" && { [ ! -x tests/lint ] || tests/lint; } && {
      [ ! -d tests/bats ] || if command -v parallel >/dev/null 2>&1; then
        bats --jobs "$(nproc)" tests/bats
      else
        bats tests/bats
      fi
    }) >&2 || ns_die "project checks failed: not tagging"
  fi

  local sha runs
  sha=$(git -C "$repo" rev-parse HEAD)
  if ! command -v gh >/dev/null 2>&1; then
    ns_warn "gh is missing: CI status not checked"
  elif ! runs=$(cd "$repo" && gh run list --commit "$sha" --json status,conclusion 2>/dev/null); then
    ns_warn "could not read CI status for $sha"
  elif [ "$(jq 'length' <<<"$runs" 2>/dev/null || echo 0)" = 0 ]; then
    ns_warn "no CI runs found for $sha"
  elif [ "$(jq '[.[] | select(.status != "completed")] | length' <<<"$runs")" != 0 ]; then
    ns_warn "CI runs are still active on $sha"
  elif [ "$(jq '[.[] | select(.conclusion != "success" and .conclusion != "skipped")] | length' <<<"$runs")" != 0 ]; then
    ns_warn "CI is not green on $sha"
  fi

  ns_tag_warn_active_runs

  local msg titles
  # merge commits ("Merge pull request #N", title in the body) and squash merges ("<title> (#N)")
  titles=$(git -C "$repo" log --first-parent --format='%s%x1f%b%x1e' ${last:+"$last..HEAD"} |
    awk 'BEGIN {RS="\036"; FS="\037"} {sub(/^\n/, "", $1)}
      $1 ~ /^Merge pull request/ {n=split($2, a, "\n"); for (i=1;i<=n;i++) if (a[i] ~ /[^[:space:]]/) {print "- " a[i]; break}; next}
      $1 ~ / \(#[0-9]+\)$/ {print "- " $1}' || true)
  msg="Release $tag"
  [ -z "$titles" ] || msg="$msg"$'\n\n'"$titles"

  if [ -z "$yes" ]; then
    ns_confirm "Tag $tag at ${sha:0:9} and push to origin?" || {
      printf 'not tagged\n'
      return 1
    }
  fi
  git -C "$repo" tag -a "$tag" -m "$msg"
  git -C "$repo" push -q origin "$tag" || {
    git -C "$repo" tag -d "$tag" >/dev/null
    ns_die "push of $tag failed: local tag removed"
  }
  printf 'tagged %s and pushed it to origin\n' "$tag"
  printf 'upgrade the server as root:\n  /opt/nightshift/current/bin/bootstrap.sh --upgrade %s\n' "$tag"
}

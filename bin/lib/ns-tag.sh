# shellcheck shell=bash
# summary: tag a release on main after safety checks (owner only)

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/profile.sh"

ns_tag_help() {
  printf 'usage: ns tag <vX.Y.Z> [--repo <dir>] [--yes]\n\n'
  printf 'Tag the base branch of a repository as a release and push the tag. Refuses when\n'
  printf 'the local branch is dirty or differs from origin, the name is not vX.Y.Z or is not\n'
  printf 'the next version, the tag exists, or the project checks fail. Warns when CI is not\n'
  printf 'green. Prints the root upgrade command. --yes skips the confirmation. Owner only.\n'
}

# ns_tag_next_ok <tag> <last>: succeeds when <tag> is the next step after <last>
ns_tag_next_ok() {
  local t="${1#v}" l="${2#v}" tm tn tp lm ln lp
  IFS=. read -r tm tn tp <<<"$t"
  IFS=. read -r lm ln lp <<<"$l"
  [ "$tm" = "$lm" ] && [ "$tn" = "$ln" ] && [ "$tp" = "$((lp + 1))" ] && return 0
  [ "$tm" = "$lm" ] && [ "$tn" = "$((ln + 1))" ] && [ "$tp" = 0 ] && return 0
  [ "$tm" = "$((lm + 1))" ] && [ "$tn" = 0 ] && [ "$tp" = 0 ] && return 0
  return 1
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

  local cmd
  cmd=$(jq -r '.commands.test // ""' <<<"$profile" 2>/dev/null) || cmd=""
  printf 'running project checks...\n'
  if [ -n "$cmd" ]; then
    (cd "$repo" && bash -c "$cmd") >&2 || ns_die "project checks failed: not tagging"
  else
    (cd "$repo" && { [ ! -x tests/lint ] || tests/lint; } && { [ ! -d tests/bats ] || bats tests/bats; }) >&2 ||
      ns_die "project checks failed: not tagging"
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

  local msg titles
  titles=$(git -C "$repo" log --first-parent --format='%s%n%b' ${last:+"$last..HEAD"} |
    awk '/^Merge pull request/ {m=1; next} m && NF {print "- " $0; m=0; next} {m=0}' || true)
  msg="Release $tag"
  [ -z "$titles" ] || msg="$msg"$'\n\n'"$titles"

  if [ -z "$yes" ]; then
    ns_confirm "Tag $tag at ${sha:0:9} and push to origin?" || {
      printf 'not tagged\n'
      return 1
    }
  fi
  git -C "$repo" tag -a "$tag" -m "$msg"
  git -C "$repo" push -q origin "$tag"
  printf 'tagged %s and pushed it to origin\n' "$tag"
  printf 'upgrade the server as root:\n  /opt/nightshift/current/bin/bootstrap.sh --upgrade %s\n' "$tag"
}

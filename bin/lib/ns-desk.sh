# shellcheck shell=bash
# summary: move desk notes into a repo

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/profile.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

NS_DESK_USAGE="ns desk import <path.md> <repo path>"

ns_desk_help() {
  printf 'usage: %s\n\n' "$NS_DESK_USAGE"
  printf 'Land a desk note in the project repo through a pull request. <path.md> is\n'
  printf 'absolute or relative to the desk directory; its first component names the\n'
  printf 'project. The note is copied to <repo path> on a new branch cut from the base\n'
  printf 'branch, pushed, and a pull request is opened. Nightshift never merges it.\n'
  printf '<repo path> may not lie under .github/workflows/ or go through a symlink on the\n'
  printf 'base branch. When a desk pull request for the same <repo path> is already open,\n'
  printf 'it is printed and no second one is opened.\n'
  printf 'To start a run from a note without touching the repo, use ns new --from-desk.\n'
}

ns_desk_cleanup() {
  git -C "$1" worktree remove --force "$2" 2>/dev/null || true
  git -C "$1" branch -D "$3" >/dev/null 2>&1 || true
}

ns_desk_main() {
  [ "${1:-}" = import ] || ns_usage "$NS_DESK_USAGE"
  shift
  [ $# -eq 2 ] || ns_usage "$NS_DESK_USAGE"
  local note="$1" rel="$2" desk src sub pname project repo path prefix branch base
  local br pr_wt body url
  desk=$(ns_desk_dir)
  case "$note" in
    /*) src="$note" ;;
    *) src="$desk/$note" ;;
  esac
  src=$(realpath -m "$src")
  [ -f "$src" ] || ns_die "$note: no such desk note"
  case "$src" in
    "$(realpath -m "$desk")"/*) sub="${src#"$(realpath -m "$desk")"/}" ;;
    *) ns_die "$note: not inside the desk $desk" ;;
  esac
  pname="${sub%%/*}"
  [ "$pname" != "$sub" ] || ns_die "$note: the note must be inside a project folder of the desk"
  case "$rel" in
    /* | ".." | ../* | */.. | */../* | "" | . | ./* | */. | */./* | *//*)
      ns_die "$rel: repo path must be relative, normalized and stay inside the repo"
      ;;
    .github/workflows | .github/workflows/*)
      ns_die "$rel: refused: files under .github/workflows/ run as CI; add a workflow by hand"
      ;;
  esac
  project=$(ns_project_by_name "$pname") || ns_die "project $pname is not registered"
  repo=$(jq -r .repo <<<"$project")
  path=$(jq -r .path <<<"$project")
  prefix=$(jq -r .prefix <<<"$project")
  branch=$(jq -r '.branch // ""' <<<"$project")
  base=$(ns_profile_json "$path" "$prefix" "$branch" 2>/dev/null | jq -r '.git.base_branch // "main"') || base=main
  [ -n "$base" ] || base=main
  ns_has_token "$(cat "$src")" && ns_die "$note: looks like it contains a token; remove it first"
  ns_token_export "${repo%%/*}"

  # one desk PR per repo path: print an open one instead of opening a second
  local open
  if open=$(gh pr list --repo "$repo" --state open --limit 200 --json number,url,title,headRefName 2>/dev/null); then
    url=$(jq -r --arg t "Add $rel from the desk" \
      '[.[] | select((.headRefName | startswith("nightshift/desk-")) and .title == $t)][0].url // empty' <<<"$open") || url=""
    if [ -n "$url" ]; then
      printf 'already open for %s: %s (no second pull request opened)\n' "$rel" "$url"
      return 0
    fi
  else
    ns_warn "could not list open pull requests; a desk pull request for $rel may already be open"
  fi

  br="nightshift/desk-$(basename "$rel" | tr -c 'A-Za-z0-9\n' '-' | sed 's/-*$//')-$(date +%s)-$RANDOM"
  pr_wt="$(ns_worktree_root)/${repo#*/}-${br#nightshift/}"
  git -C "$path" fetch -q origin "$base" || ns_die "could not fetch origin $base in $path"
  # refuse a repo path that goes through (or is) a symlink on the base branch
  local prefix="" rest="$rel"
  while :; do
    prefix="${prefix:+$prefix/}${rest%%/*}"
    if [ "$(git -C "$path" ls-tree "origin/$base" -- "$prefix" | cut -c1-6)" = 120000 ]; then
      ns_die "$rel: $prefix is a symlink on $base; refused"
    fi
    [ "$rest" != "${rest#*/}" ] || break
    rest="${rest#*/}"
  done
  mkdir -p "$(dirname "$pr_wt")"
  git -C "$path" worktree add -q -b "$br" "$pr_wt" "origin/$base" || ns_die "could not create worktree $pr_wt"
  body=$(mktemp)
  mkdir -p "$(dirname "$pr_wt/$rel")"
  cp "$src" "$pr_wt/$rel"
  # shellcheck disable=SC2016
  printf 'Adds the desk note `%s` as `%s`. Review it, then merge.\n' "$sub" "$rel" >"$body"
  git -C "$pr_wt" add -f -- "$rel"
  git -C "$pr_wt" commit -q -m "ns: import desk note $rel"
  if ! git -C "$pr_wt" push -q -u origin "$br"; then
    rm -f "$body"
    ns_desk_cleanup "$path" "$pr_wt" "$br"
    ns_die "could not push $br"
  fi
  if ! url=$(gh pr create --repo "$repo" --base "$base" --head "$br" --title "Add $rel from the desk" --body-file "$body"); then
    rm -f "$body"
    ns_desk_cleanup "$path" "$pr_wt" "$br"
    ns_die "gh pr create failed"
  fi
  rm -f "$body"
  ns_desk_cleanup "$path" "$pr_wt" "$br"
  printf 'opened %s (not merged: merge it on GitHub)\n' "$url"
}

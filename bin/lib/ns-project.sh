# shellcheck shell=bash
# summary: add a project

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/stacks.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/profile.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/ns-new.sh"

ns_project_help() {
  printf 'usage: ns project add <owner/repo> --prefix <p> [--sandbox] [--branch <b>]\n\n'
  printf 'Register a project: clone (or adopt) it under the coding directory, run the\n'
  printf 'stack setup, create its desk folder and add it to projects.yaml.\n'
}

ns_project_add() {
  local u="ns project add <owner/repo> --prefix <p> [--sandbox] [--branch <b>]"
  local repo="" prefix="" sandbox=false branch="" owner name path existing wt base url rc=0 profile
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix)
        [ $# -ge 2 ] || ns_usage "$u"
        prefix="$2"
        shift 2
        ;;
      --branch)
        [ $# -ge 2 ] || ns_usage "$u"
        branch="$2"
        shift 2
        ;;
      --sandbox)
        sandbox=true
        shift
        ;;
      -*) ns_usage "$u" ;;
      *)
        [ -z "$repo" ] || ns_usage "$u"
        repo="$1"
        shift
        ;;
    esac
  done
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || ns_usage "$u"
  [[ $prefix =~ ^[a-z][a-z0-9]{0,9}$ ]] || ns_usage "$u"
  owner=${repo%%/*}
  name=${repo#*/}

  existing=$(ns_projects_json | jq -r --arg r "$repo" '.[] | select(.repo == $r) | .prefix' | head -n1)
  if [ -n "$existing" ]; then
    if [ "$existing" = "$prefix" ]; then
      printf 'already registered: %s (prefix %s)\n' "$repo" "$prefix"
      return 0
    fi
    ns_die "$repo is already registered with prefix $existing"
  fi
  if existing=$(ns_project_by_prefix "$prefix"); then
    ns_die "prefix $prefix is used by $(jq -r .repo <<<"$existing")"
  fi

  [ -d "$(ns_desk_dir)" ] || ns_die "desk $(ns_desk_dir) not found: run bootstrap.sh or set NS_DESK_DIR"

  ns_token_export "$owner"

  path="$(ns_coding_dir)/$name"
  if [ -e "$path" ]; then
    url=$(git -C "$path" remote get-url origin 2>/dev/null) || url=""
    case "$url" in
      *[:/]"$repo" | *[:/]"$repo.git") ;;
      *) ns_die "$path exists and is not a clone of $repo" ;;
    esac
    git -C "$path" fetch -q origin || ns_die "could not fetch origin in $path"
  else
    mkdir -p "$(ns_coding_dir)"
    gh repo clone "$repo" "$path" -- -q || ns_die "could not clone $repo"
  fi

  base="$branch"
  if [ -z "$base" ]; then
    base=$(git -C "$path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || base=origin/main
    base=${base#origin/}
  fi

  profile=$(ns_profile_json "$path" "$prefix" "$branch") || rc=$?
  if [ "$rc" -eq 0 ]; then
    wt="$(ns_worktree_root)/$name-profilecheck"
    mkdir -p "$(ns_worktree_root)"
    if [ -e "$wt" ]; then
      git -C "$path" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
      git -C "$path" worktree prune
    fi
    git -C "$path" worktree add -q --detach "$wt" "origin/$base" || ns_die "could not create worktree $wt"
    if ! python3 "$NS_HOME/bin/lib/profile.py" check "$wt/.claude/project-profile.yaml" --repo "$wt"; then
      git -C "$path" worktree remove --force "$wt"
      ns_die "the profile on $base is not valid; $repo was not registered"
    fi
    if ! ns_stack_setup "$wt" "$profile"; then
      git -C "$path" worktree remove --force "$wt"
      ns_die "stack setup failed; $repo was not registered"
    fi
    git -C "$path" worktree remove --force "$wt"
  elif [ "$rc" -eq 3 ]; then
    printf 'no .claude/project-profile.yaml on %s\n' "$base"
  else
    ns_die "could not read the profile of $repo"
  fi

  mkdir -p "$(ns_desk_dir)/$name/runs"
  ns_project_register "$(jq -nc --arg n "$name" --arg r "$repo" --arg p "$path" --arg x "$prefix" \
    --argjson s "$sandbox" --arg b "$branch" \
    '{name: $n, repo: $r, path: $p, prefix: $x, sandbox: $s} + (if $b == "" then {} else {branch: $b} end)')"
  printf 'added %s as %s at %s\n' "$repo" "$prefix" "$path"
  if [ "$rc" -eq 3 ]; then
    printf 'starting onboarding run %s-onboard\n' "$prefix"
    ns_new_main "$prefix-onboard" --onboard
  fi
}

ns_project_main() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    add) ns_project_add "$@" ;;
    *) ns_usage "ns project add <owner/repo> --prefix <p> [--sandbox] [--branch <b>]" ;;
  esac
}

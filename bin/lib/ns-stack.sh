# shellcheck shell=bash
# summary: show, merge or drop the stack of open run PRs

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/stack-pr.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/profile.sh"

ns_stack_help() {
  printf 'usage: ns stack [project]\n'
  printf '       ns stack merge [project] [--dry-run]\n'
  printf '       ns stack drop <id> [--dry-run]\n\n'
  printf 'List the open pull requests of runs, bottom to top (main <- a <- b), one block per chain: run, PR, base,\n'
  printf 'checks, review state and age. project is a prefix or name; without it every project is shown.\n'
  printf 'merge lands the stack bottom to top (owner only): each PR must be approved, have no failing checks and be\n'
  printf 'mergeable; the next PR is retargeted to the base branch before the one below it is merged. It stops at the\n'
  printf 'first PR that is not ready and says what is left. drop closes the PR of run <id> and restacks the PR above it\n'
  printf 'onto the layer below (owner only). --dry-run prints the plan and changes nothing.\n'
}

ns_stack_main() {
  case "${1:-}" in
    merge)
      shift
      ns_stack_merge "$@"
      return
      ;;
    drop)
      shift
      ns_stack_drop "$@"
      return
      ;;
  esac
  ns_stack_list "$@"
}

ns_stack_list() {
  local u="ns stack [project]" sel="" projects p repo prefix prof path branch fixpat featpat prs n
  while [ $# -gt 0 ]; do
    case "$1" in
      -*) ns_usage "$u" ;;
      *)
        [ -z "$sel" ] || ns_usage "$u"
        sel="$1"
        ;;
    esac
    shift
  done
  projects=$(ns_projects_json)
  if [ -n "$sel" ]; then
    projects=$(jq -c --arg s "$sel" '[.[] | select(.prefix == $s or .name == $s or .repo == $s)]' <<<"$projects")
    [ "$(jq length <<<"$projects")" -gt 0 ] || ns_die "unknown project $sel"
  fi
  [ "$(jq length <<<"$projects")" -gt 0 ] || {
    printf 'no projects\n'
    return 0
  }
  while IFS= read -r p; do
    repo=$(jq -r .repo <<<"$p")
    prefix=$(jq -r .prefix <<<"$p")
    path=$(jq -r .path <<<"$p")
    branch=$(jq -r '.branch // ""' <<<"$p")
    prof=$(ns_profile_json "$path" "$prefix" "$branch" 2>/dev/null) || [ $? -eq 3 ] || ns_die "could not read the profile of $repo"
    fixpat=$(jq -r '.git.fix_branch' <<<"$prof")
    featpat=$(jq -r '.git.feature_branch' <<<"$prof")
    prs=$(ns_stack_open_prs "$repo" "$fixpat" "$featpat" "$prefix" "$path") || ns_die "could not list the pull requests of $repo"
    printf '%s\n' "$repo"
    n=$(jq length <<<"$prs")
    if [ "$n" = 0 ]; then
      printf '  no open run PRs\n'
      continue
    fi
    local row age chains nch ci closed note
    closed=$(ns_stack_closed_heads "$repo")
    chains=$(ns_stack_chains "$prs")
    nch=$(jq length <<<"$chains")
    for ((ci = 0; ci < nch; ci++)); do
      [ "$nch" -le 1 ] || printf '  chain %d\n' $((ci + 1))
      printf '  %-12s %-6s %-22s %-8s %-18s %s\n' RUN PR BASE CHECKS REVIEW AGE
      while IFS= read -r row; do
        age=$(ns_age "$(jq -r .createdAt <<<"$row")" 2>/dev/null) || age="-"
        note=""
        if [ -n "$closed" ] && grep -qxF -- "$(jq -r .base <<<"$row")" <<<"$closed"; then note="  base closed"; fi
        printf '  %-12s %-6s %-22s %-8s %-18s %s%s\n' "$(jq -r .run <<<"$row")" "#$(jq -r .number <<<"$row")" \
          "$(jq -r .base <<<"$row")" "$(ns_stack_checks_state "$(jq -c .statusCheckRollup <<<"$row")")" \
          "$(jq -r 'if .reviewDecision == "" then "-" else .reviewDecision end' <<<"$row")" "$age" "$note"
      done < <(jq -c ".[$ci][]" <<<"$chains")
    done
  done < <(jq -c '.[]' <<<"$projects")
}

# ns_stack_merge [project] [--dry-run]: land the single chain of run PRs bottom to top
ns_stack_merge() {
  local u="ns stack merge [project] [--dry-run]" sel="" dry=0 projects p repo prs chains n i row num head base why live
  local merged=() left=() nxt
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      -h | --help)
        ns_stack_help
        return 0
        ;;
      -*) ns_usage "$u" ;;
      *)
        [ -z "$sel" ] || ns_usage "$u"
        sel="$1"
        ;;
    esac
    shift
  done
  projects=$(ns_projects_json)
  if [ -n "$sel" ]; then
    p=$(ns_stack_find_project "$sel") || ns_die "unknown project $sel"
  else
    [ "$(jq length <<<"$projects")" -eq 1 ] || ns_usage "$u"
    p=$(jq -c '.[0]' <<<"$projects")
  fi
  repo=$(jq -r .repo <<<"$p")
  ns_token_export "${repo%%/*}"
  prs=$(ns_stack_project_prs "$p") || ns_die "could not list the pull requests of $repo"
  chains=$(ns_stack_chains "$prs")
  case "$(jq length <<<"$chains")" in
    0)
      printf 'no open run PRs in %s\n' "$repo"
      return 0
      ;;
    1) ;;
    *) ns_die "more than one chain of run PRs is open in $repo; merge or drop until one is left" ;;
  esac
  n=$(jq '.[0] | length' <<<"$chains")
  base=$(jq -r '.[0][0].base' <<<"$chains")
  if [ "$dry" -eq 1 ]; then
    printf 'plan for %s (dry run, nothing is changed):\n' "$repo"
    for ((i = 0; i < n; i++)); do
      row=$(jq -c ".[0][$i]" <<<"$chains")
      live=$(gh pr view "$(jq -r .number <<<"$row")" --repo "$repo" --json mergeable,reviewDecision,state 2>/dev/null) || live='{}'
      why=$(ns_stack_gate "$row" "$live")
      printf '  %d. merge #%s (%s) into %s%s\n' $((i + 1)) "$(jq -r .number <<<"$row")" "$(jq -r .run <<<"$row")" "$base" \
        "${why:+; blocked: it $why}"
    done
    return 0
  fi
  for ((i = 0; i < n; i++)); do
    row=$(jq -c ".[0][$i]" <<<"$chains")
    num=$(jq -r .number <<<"$row")
    head=$(jq -r .head <<<"$row")
    live=$(gh pr view "$num" --repo "$repo" --json mergeable,reviewDecision,state 2>/dev/null) || live='{}'
    why=$(ns_stack_gate "$row" "$live")
    if [ -n "$why" ]; then
      printf 'stopped: #%s %s\n' "$num" "$why"
      break
    fi
    nxt=""
    if [ $((i + 1)) -lt "$n" ]; then
      nxt=$(jq -r ".[0][$((i + 1))].number" <<<"$chains")
      if ! gh pr edit "$nxt" --repo "$repo" --base "$base" >/dev/null; then
        printf 'stopped: could not retarget #%s to %s\n' "$nxt" "$base"
        break
      fi
    fi
    if ! gh pr merge "$num" --repo "$repo" --merge >/dev/null; then
      printf 'stopped: could not merge #%s\n' "$num"
      [ -z "$nxt" ] || gh pr edit "$nxt" --repo "$repo" --base "$head" >/dev/null 2>&1 || true
      break
    fi
    merged+=("#$num")
  done
  printf 'merged: %s\n' "${merged[*]:-none}"
  for ((i = ${#merged[@]}; i < n; i++)); do left+=("#$(jq -r ".[0][$i].number" <<<"$chains")"); done
  if [ "${#left[@]}" -gt 0 ]; then
    printf 'left: %s\n' "${left[*]}"
    return 1
  fi
}

# ns_stack_drop <id> [--dry-run]: close the PR of a run and restack the PR above it onto the layer below
ns_stack_drop() {
  local u="ns stack drop <id> [--dry-run]" id="" dry=0 p repo prs row num head base above anum ahead wt path name rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      -h | --help)
        ns_stack_help
        return 0
        ;;
      -*) ns_usage "$u" ;;
      *)
        [ -z "$id" ] || ns_usage "$u"
        id="$1"
        ;;
    esac
    shift
  done
  [ -n "$id" ] || ns_usage "$u"
  p=$(ns_project_by_prefix "${id%%-*}") || ns_die "no project for run $id"
  repo=$(jq -r .repo <<<"$p")
  path=$(jq -r .path <<<"$p")
  name=$(jq -r .name <<<"$p")
  ns_token_export "${repo%%/*}"
  prs=$(ns_stack_project_prs "$p") || ns_die "could not list the pull requests of $repo"
  row=$(jq -c --arg r "$id" '[.[] | select(.run == $r)] | first // empty' <<<"$prs")
  [ -n "$row" ] || ns_die "no open run PR for $id in $repo"
  num=$(jq -r .number <<<"$row")
  head=$(jq -r .head <<<"$row")
  base=$(jq -r .base <<<"$row")
  above=$(jq -c --arg h "$head" '[.[] | select(.base == $h)] | first // empty' <<<"$prs")
  if [ -n "$above" ]; then
    anum=$(jq -r .number <<<"$above")
    ahead=$(jq -r .head <<<"$above")
  fi
  if [ "$dry" -eq 1 ]; then
    printf 'plan for %s (dry run, nothing is changed):\n' "$id"
    if [ -n "$above" ]; then
      printf '  1. merge %s into %s and push it\n' "$base" "$ahead"
      printf '  2. retarget #%s to %s\n' "$anum" "$base"
      printf '  3. close #%s\n' "$num"
    else
      printf '  1. close #%s (nothing is stacked on it)\n' "$num"
    fi
    return 0
  fi
  if [ -n "$above" ]; then
    git -C "$path" fetch -q origin || ns_die "could not fetch $repo"
    wt="$(ns_worktree_root)/$name-$id--drop"
    mkdir -p "$(ns_worktree_root)"
    if [ -e "$wt" ]; then
      git -C "$path" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
      git -C "$path" worktree prune
    fi
    git -C "$path" worktree add -q --detach "$wt" "origin/$ahead" || ns_die "could not create worktree $wt"
    if ! git -C "$wt" merge -q --no-edit "origin/$base" >/dev/null 2>&1; then
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      git -C "$path" worktree remove --force "$wt"
      ns_die "conflict merging $base into $ahead (PR #$anum): resolve it by hand; #$num is still open"
    fi
    git -C "$wt" push -q origin "HEAD:refs/heads/$ahead" || rc=$?
    git -C "$path" worktree remove --force "$wt"
    [ "$rc" -eq 0 ] || ns_die "could not push $ahead (PR #$anum); #$num is still open"
    gh pr edit "$anum" --repo "$repo" --base "$base" >/dev/null || ns_die "could not retarget #$anum to $base; #$num is still open"
  fi
  gh pr close "$num" --repo "$repo" >/dev/null || ns_die "could not close #$num"
  printf 'closed #%s (%s)\n' "$num" "$id"
  [ -z "$above" ] || printf 'restacked #%s onto %s\n' "$anum" "$base"
}

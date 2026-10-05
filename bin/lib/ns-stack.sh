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
  printf 'merge lands the stack bottom to top (owner only): the profile checks run once on the top of the stack, then each PR must be approved, have no failing checks and be\n'
  printf 'mergeable; the next PR is retargeted to the base branch before the one below it is merged. It stops at the\n'
  printf 'first PR that is not ready and says what is left. drop closes the PR of run <id> and restacks the PR above it\n'
  printf 'onto the layer below and reverts the dropped change in it (owner only). --dry-run prints the plan and changes nothing.\n'
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
  local merged=() left=() nxt topnum id_for_wt
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
  id_for_wt=$(jq -r '.[0][-1].run' <<<"$chains")
  if [ "$dry" -eq 1 ]; then
    printf 'plan for %s (dry run, nothing is changed):\n' "$repo"
    printf '  0. run the profile checks on the top of the stack (#%s)\n' "$(jq -r '.[0][-1].number' <<<"$chains")"
    for ((i = 0; i < n; i++)); do
      row=$(jq -c ".[0][$i]" <<<"$chains")
      live=$(gh pr view "$(jq -r .number <<<"$row")" --repo "$repo" --json mergeable,reviewDecision,statusCheckRollup,state 2>/dev/null) || live='{}'
      why=$(ns_stack_gate "$row" "$live")
      printf '  %d. merge #%s (%s) into %s%s\n' $((i + 1)) "$(jq -r .number <<<"$row")" "$(jq -r .run <<<"$row")" "$base" \
        "${why:+; blocked: it $why}"
    done
    return 0
  fi
  topnum=$(jq -r '.[0][-1].number' <<<"$chains")
  ns_stack_top_checks "$p" "$id_for_wt" "$(jq -r '.[0][-1].head' <<<"$chains")" || {
    printf 'stopped: checks failed on top of the stack (#%s)\n' "$topnum"
    return 1
  }
  for ((i = 0; i < n; i++)); do
    row=$(jq -c ".[0][$i]" <<<"$chains")
    num=$(jq -r .number <<<"$row")
    head=$(jq -r .head <<<"$row")
    live=$(gh pr view "$num" --repo "$repo" --json mergeable,reviewDecision,statusCheckRollup,state 2>/dev/null) || live='{}'
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
      [ -z "$nxt" ] || gh pr edit "$nxt" --repo "$repo" --base "$head" >/dev/null 2>&1 \
        || printf 'warning: could not retarget #%s back to %s; it still targets %s\n' "$nxt" "$head" "$base"
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

# ns_stack_top_checks <project json> <run id> <head branch>: run the profile checks in a throwaway worktree
# of the top PR's head; a non-zero return means a check failed or could not run
ns_stack_top_checks() {
  local p="$1" id="$2" head="$3" path name prof wt total n cmd cname stack crc failed=0
  path=$(jq -r .path <<<"$p")
  name=$(jq -r .name <<<"$p")
  prof=$(ns_profile_json "$path" "$(jq -r .prefix <<<"$p")" "$(jq -r '.branch // ""' <<<"$p")" 2>/dev/null) || [ $? -eq 3 ] || {
    printf 'could not read the profile of %s\n' "$name"
    return 1
  }
  git -C "$path" fetch -q origin || {
    printf 'could not fetch origin for %s\n' "$name"
    return 1
  }
  wt="$(ns_worktree_root)/$name-$id--merge"
  mkdir -p "$(ns_worktree_root)"
  if [ -e "$wt" ]; then
    git -C "$path" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    git -C "$path" worktree prune
  fi
  git -C "$path" worktree add -q --detach "$wt" "origin/$head" || {
    printf 'could not create a worktree of %s\n' "$head"
    return 1
  }
  total=$(jq '(.checks // []) | length' <<<"$prof")
  [ "$total" -gt 0 ] || printf 'no checks configured\n'
  for ((n = 0; n < total; n++)); do
    stack=$(jq -r ".checks[$n].stack" <<<"$prof")
    cname=$(jq -r ".checks[$n].name" <<<"$prof")
    cmd=$(jq -r ".checks[$n].cmd" <<<"$prof")
    crc=0
    (cd "$wt" && env -i HOME="${HOME:-}" PATH="$PATH" LANG="${LANG:-C.UTF-8}" TERM="${TERM:-dumb}" \
      TMPDIR="${TMPDIR:-/tmp}" bash -c "$cmd") >/dev/null 2>&1 </dev/null || crc=$?
    if [ "$crc" -eq 0 ]; then
      printf 'check %s %s: pass\n' "$stack" "$cname"
    elif [ "$crc" -eq 5 ] && [[ $cmd == *pytest* ]]; then
      printf 'check %s %s: skipped (no tests)\n' "$stack" "$cname"
    else
      printf 'check %s %s: FAIL\n' "$stack" "$cname"
      failed=1
    fi
  done
  git -C "$path" worktree remove --force "$wt" 2>/dev/null || true
  return "$failed"
}

# ns_stack_drop <id> [--dry-run]: close the PR of a run and restack the PR above it onto the layer below
ns_stack_drop() {
  local u="ns stack drop <id> [--dry-run]" id="" dry=0 p repo prs row num head base above anum ahead wt path name why rc=0
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
      printf '  1. merge %s into %s\n' "$base" "$ahead"
      printf '  2. revert the change of %s (%s...%s) in %s and push it\n' "$id" "$base" "$head" "$ahead"
      printf '  3. retarget #%s to %s\n' "$anum" "$base"
      printf '  4. close #%s\n' "$num"
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
      if [ -n "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
        why="conflict merging $base into $ahead (PR #$anum): resolve it by hand"
      else
        why="could not merge $base into $ahead (PR #$anum): $(git -C "$wt" merge --no-edit "origin/$base" 2>&1 | tr '\n' ' ')"
      fi
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      git -C "$path" worktree remove --force "$wt"
      ns_die "$why; #$num is still open"
    fi
    # the branch above holds every commit of the dropped layer: take its change out again
    if ! git -C "$wt" diff "origin/$base...origin/$head" >"$wt.revert.patch" 2>/dev/null; then
      rm -f "$wt.revert.patch"
      git -C "$path" worktree remove --force "$wt"
      ns_die "could not compute the change of $id; #$num is still open"
    fi
    if [ -s "$wt.revert.patch" ]; then
      if ! git -C "$wt" apply -R --index "$wt.revert.patch" >/dev/null 2>&1; then
        rm -f "$wt.revert.patch"
        git -C "$path" worktree remove --force "$wt"
        ns_die "the change of $id does not revert cleanly in $ahead (PR #$anum): revert it by hand; #$num is still open"
      fi
      if ! git -C "$wt" commit -q -m "Revert $id (dropped from the stack)" >/dev/null 2>&1; then
        rm -f "$wt.revert.patch"
        git -C "$path" worktree remove --force "$wt"
        ns_die "could not commit the revert of $id in $ahead (PR #$anum); #$num is still open"
      fi
    fi
    rm -f "$wt.revert.patch"
    git -C "$wt" push -q origin "HEAD:refs/heads/$ahead" || rc=$?
    git -C "$path" worktree remove --force "$wt"
    [ "$rc" -eq 0 ] || ns_die "could not push $ahead (PR #$anum); #$num is still open"
    gh pr edit "$anum" --repo "$repo" --base "$base" >/dev/null || ns_die "could not retarget #$anum to $base; #$num is still open"
  fi
  gh pr close "$num" --repo "$repo" >/dev/null || ns_die "could not close #$num"
  printf 'closed #%s (%s)\n' "$num" "$id"
  [ -z "$above" ] || printf 'restacked #%s onto %s (the change of %s was reverted in it)\n' "$anum" "$base" "$id"
}

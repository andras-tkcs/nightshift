# shellcheck shell=bash
# summary: show the stack of open run PRs

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/stack-pr.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/profile.sh"

ns_stack_help() {
  printf 'usage: ns stack [project]\n\n'
  printf 'List the open pull requests of runs, bottom to top (main <- a <- b), one block per chain: run, PR, base,\n'
  printf 'checks, review state and age. project is a prefix or name; without it every project is shown.\n'
}

ns_stack_main() {
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

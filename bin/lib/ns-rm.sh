# shellcheck shell=bash
# summary: remove a finished run (alias purge)

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/ns-gc.sh"

ns_rm_help() {
  printf 'usage: ns rm <id> [--force] [--remote] [--dry-run] [--yes]\n'
  printf '       ns rm --all-stopped [--force] [--remote] [--dry-run] [--yes]\n\n'
  printf 'Removes a stopped, failed, parked or done run (alias: ns purge): its worktrees, local\n'
  printf 'branches, tmux session and desk folder (moved to the desk archive); the run stays in\n'
  printf '"ns ls --all". Running or queued runs are refused (use ns stop or ns kill first).\n'
  printf 'Uncommitted or unpushed work is refused unless --force. Remote branches are deleted\n'
  printf 'only with --remote; an open PR is then closed with a comment. --dry-run lists what\n'
  printf 'would go; --yes skips the confirmation. --all-stopped covers every stopped, failed or\n'
  printf 'parked run that is not archived.\n'
}

RM_FORCE=0
RM_REMOTE=0
RM_YES=0

# rm_inner <run-json>: the owner token is already exported
rm_inner() {
  local run="$1" id pname base proj ledger state pr prstate rc=0
  id=$(jq -r .id <<<"$run")
  pname=$(jq -r .project <<<"$run")
  base=$(jq -r '.worktree // ""' <<<"$run")
  proj=$(ns_project_by_name "$pname") || {
    ns_warn "$id: unknown project $pname"
    return 1
  }
  ledger="$base/.nightshift/runs/$id/ledger.yaml"
  [ -n "$base" ] && [ -f "$ledger" ] || {
    ns_warn "$id: no ledger (worktree missing), nothing to remove safely"
    return 1
  }
  state=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.state // ""')
  case "$state" in
    stopped | failed | parked | done) ;;
    *)
      ns_warn "$id is $state: stop it first (ns stop $id, or ns kill $id)"
      return 1
      ;;
  esac

  local dry=$GC_DRY
  if [ "$dry" = 0 ] && [ "$RM_YES" = 0 ]; then
    GC_DRY=1
    gc_cleanup_run "$run" "$proj" "$RM_REMOTE" "$RM_FORCE" || rc=$?
    GC_DRY=0
    [ "$rc" = 0 ] || return "$rc"
    ns_confirm "Remove run $id?" || {
      printf 'kept %s\n' "$id"
      return 0
    }
  fi

  pr=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.pr // ""')
  if [ "$RM_REMOTE" = 2 ] && [ -n "$pr" ]; then
    prstate=$(gh pr view "$pr" --json state -q .state 2>/dev/null) || prstate=""
    if [ "$prstate" = OPEN ]; then
      if [ "$dry" = 1 ]; then
        printf 'would close PR %s\n' "$pr"
      else
        gh pr close "$pr" --comment "Closed by ns rm $id." >/dev/null || ns_warn "could not close $pr"
        printf 'closed PR %s\n' "$pr"
      fi
    fi
  fi
  gc_cleanup_run "$run" "$proj" "$RM_REMOTE" "$RM_FORCE" || rc=$?
  return "$rc"
}

ns_rm_main() {
  local u="ns rm <id> [--force] [--remote] [--dry-run] [--yes] | ns rm --all-stopped [...]"
  local id="" all=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) RM_FORCE=1 ;;
      --remote) RM_REMOTE=2 ;;
      --dry-run) GC_DRY=1 ;;
      --yes) RM_YES=1 ;;
      --all-stopped) all=1 ;;
      -*) ns_usage "$u" ;;
      *)
        [ -z "$id" ] || ns_usage "$u"
        id="$1"
        ;;
    esac
    shift
  done
  if [ "$all" = 1 ]; then [ -z "$id" ] || ns_usage "$u"; else [ -n "$id" ] || ns_usage "$u"; fi
  ns_load_env

  local -a runs=()
  local run rc=0 st
  if [ "$all" = 1 ]; then
    while IFS= read -r run; do
      [ -n "$run" ] || continue
      st=$(jq -r '.worktree // ""' <<<"$run")
      st=$("$NS_HOME/bin/ns-ledger" get "$st/.nightshift/runs/$(jq -r .id <<<"$run")/ledger.yaml" '.state // ""' 2>/dev/null) || continue
      case "$st" in stopped | failed | parked) runs+=("$run") ;; esac
    done < <(ns_runs_json | jq -c '.[] | select(.archived | not)')
  else
    run=$(ns_run_get "$id") || ns_die "unknown run $id"
    runs+=("$run")
  fi

  export GC_INNER=rm_inner
  for run in "${runs[@]}"; do
    gc_run "$run" || rc=1
  done
  [ "$GC_NEEDS" = 0 ] || rc=1
  return "$rc"
}

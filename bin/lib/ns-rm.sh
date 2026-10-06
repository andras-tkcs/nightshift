# shellcheck shell=bash
# summary: remove a finished run (alias purge)

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/ns-gc.sh"

ns_rm_help() {
  printf 'usage: ns rm <id> [--force] [--remote] [--forget] [--dry-run] [--yes]\n'
  printf '       ns rm --all-stopped [--force] [--remote] [--dry-run] [--yes]\n\n'
  printf 'Removes a stopped, failed, parked or done run (alias: ns purge): its worktrees, local\n'
  printf 'branches, tmux session and desk folder (moved to the desk archive); the run stays in\n'
  printf '"ns ls --all". Running or queued runs are refused (use ns stop or ns kill first).\n'
  printf 'Uncommitted or unpushed work is refused unless --force. Remote branches are deleted\n'
  printf 'only with --remote; an open PR is then closed with a comment. A run whose worktree is\n'
  printf 'already gone (removed before) is read from origin/<plan branch>, so a later\n'
  printf '"ns rm <id> --remote" still deletes its remote branches. --forget also drops the run\n'
  printf 'from the runs index so "ns new <id>" can start the id again; it refuses while the\n'
  printf 'plan branch is on origin unless --remote is given in the same call. --dry-run lists\n'
  printf 'what would go; --yes skips the confirmation. --all-stopped covers every stopped,\n'
  printf 'failed or parked run that is not archived (no --forget).\n'
}

RM_FORCE=0
RM_REMOTE=0
RM_FORGET=0
RM_YES=0

# rm_inner <run-json>: the owner token is already exported
rm_inner() {
  local tmp rc=0
  tmp=$(mktemp)
  rm_one "$1" "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

# rm_one <run-json> <scratch file for a ledger read from origin>
rm_one() {
  local run="$1" tmp="$2" id pname base proj path plan archived ledger state pr prstate orc rc=0
  id=$(jq -r .id <<<"$run")
  pname=$(jq -r .project <<<"$run")
  base=$(jq -r '.worktree // ""' <<<"$run")
  plan=$(jq -r '.branch // ""' <<<"$run")
  archived=$(jq -r '.archived // false' <<<"$run")
  proj=$(ns_project_by_name "$pname") || {
    ns_warn "$id: unknown project $pname"
    return 1
  }
  path=$(jq -r .path <<<"$proj")
  ledger="$base/.nightshift/runs/$id/ledger.yaml"
  # check: the ledger's state decides; an archived run whose worktree is gone was already
  # removable when it was archived (its ledger on origin may hold an older state)
  local check=1
  if [ -z "$base" ] || [ ! -f "$ledger" ]; then
    # the worktree is gone (an earlier ns rm): the ledger on origin/<plan> names the branches
    orc=0
    ns_run_origin_ledger "$run" "$tmp" >/dev/null || orc=$?
    case "$orc" in
      0)
        ledger=$tmp
        printf '%s: worktree is gone, read the ledger from origin/%s\n' "$id" "$plan"
        ;;
      3)
        if [ "$RM_REMOTE" = 2 ] || [ "$RM_FORGET" = 1 ]; then
          ns_warn "$id: cannot fetch origin/$plan to read the ledger; kept the run"
          return 1
        fi
        ledger=""
        ;;
      4)
        ns_warn "$id: run id or plan branch '$plan' is not valid; kept the run"
        return 1
        ;;
      *) ledger="" ;;
    esac
    if [ "$archived" = true ]; then
      check=0
    elif [ -z "$ledger" ]; then
      ns_warn "$id: no ledger (worktree missing, none on origin/$plan), nothing to remove safely"
      return 1
    fi
  fi
  if [ "$check" = 1 ]; then
    state=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.state // ""')
    case "$state" in
      stopped | failed | parked | done) ;;
      *)
        ns_warn "$id is $state: stop it first (ns stop $id, or ns kill $id)"
        return 1
        ;;
    esac
  fi
  # an archived run with a live session was resumed
  if [ "$archived" = true ] && ns_tmux_has "$id"; then
    ns_warn "$id is archived but its tmux session is alive (resumed?): stop it first (ns stop $id, or ns kill $id)"
    return 1
  fi

  # --forget without --remote: the entry goes only once plan/<id> is gone from origin
  if [ "$RM_FORGET" = 1 ] && [ "$RM_REMOTE" != 2 ] && [ -n "$plan" ]; then
    orc=0
    ns_origin_has_branch "$path" "$plan" || orc=$?
    if [ "$orc" = 0 ]; then
      ns_warn "$id: $plan is still on origin: add --remote to delete it (ns rm $id --forget --remote), or keep the run"
      return 1
    elif [ "$orc" != 2 ]; then
      ns_warn "$id: cannot check origin for $plan; kept the run"
      return 1
    fi
  fi

  local dry=$GC_DRY out what="Remove run $id?"
  [ "$RM_FORGET" = 0 ] || what="Remove run $id and forget it?"
  if [ "$dry" = 0 ]; then
    # preview first: a refused run (unsaved work) must have no side effects, PR included
    GC_DRY=1
    out=$(gc_cleanup_run "$run" "$proj" "$RM_REMOTE" "$RM_FORCE" "$ledger" 2>&1) || rc=$?
    GC_DRY=0
    if [ "$rc" != 0 ] || [ "$RM_YES" = 0 ]; then printf '%s\n' "$out"; fi
    [ "$rc" = 0 ] || return "$rc"
    if [ "$RM_YES" = 0 ]; then
      ns_confirm "$what" || {
        printf 'kept %s\n' "$id"
        return 0
      }
    fi
  fi

  pr=""
  if [ -n "$ledger" ]; then pr=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.pr // ""'); fi
  if [ "$RM_REMOTE" = 2 ] && [ -n "$pr" ]; then
    prstate=$(gh pr view "$pr" --json state -q .state 2>/dev/null) || prstate=""
    if [ "$prstate" = OPEN ]; then
      if [ "$dry" = 1 ]; then
        printf 'would close PR %s\n' "$pr"
      else
        if gh pr close "$pr" --comment "Closed by ns rm $id." >/dev/null; then
          printf 'closed PR %s\n' "$pr"
        else
          ns_warn "could not close $pr"
        fi
      fi
    fi
  fi
  local errs=$GC_ERRORS needs=$GC_NEEDS
  gc_cleanup_run "$run" "$proj" "$RM_REMOTE" "$RM_FORCE" "$ledger" || rc=$?
  [ "$rc" = 0 ] || return "$rc"

  [ "$RM_FORGET" = 1 ] || return 0
  if [ "$dry" = 1 ]; then
    printf 'would forget %s (drop it from runs.yaml so the id can be reused)\n' "$id"
    return 0
  fi
  # forget only a run that is gone everywhere: no failed step, no worktree, no plan branch
  local left=""
  if [ "$GC_ERRORS" != "$errs" ] || [ "$GC_NEEDS" != "$needs" ]; then
    left="the removal did not finish"
  elif [ -n "$base" ] && [ -e "$base" ]; then
    left="worktree $base is still there"
  elif [ -n "$plan" ] && git -C "$path" show-ref -q --verify "refs/heads/$plan"; then
    left="local branch $plan is still there"
  elif [ -n "$plan" ]; then
    orc=0
    ns_origin_has_branch "$path" "$plan" || orc=$?
    [ "$orc" = 2 ] || left="$plan may still be on origin"
  fi
  if [ -n "$left" ]; then
    ns_warn "$id: $left; kept the run in runs.yaml"
    return 1
  fi
  ns_runs_json | jq -c --arg id "$id" 'map(select(.id != $id))' | ns_runs_write
  printf 'forgot %s: ns new %s can start it again\n' "$id" "$id"
}

ns_rm_main() {
  local u="ns rm <id> [--force] [--remote] [--forget] [--dry-run] [--yes] | ns rm --all-stopped [...]"
  local id="" all=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) RM_FORCE=1 ;;
      --remote) RM_REMOTE=2 ;;
      --forget) RM_FORGET=1 ;;
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
  if [ "$all" = 1 ]; then [ -z "$id" ] && [ "$RM_FORGET" = 0 ] || ns_usage "$u"; else [ -n "$id" ] || ns_usage "$u"; fi
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

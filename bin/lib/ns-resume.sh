# shellcheck shell=bash
# summary: restart parked, crashed or stopped runs

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/pool.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/profile.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/queue.sh"

ns_resume_help() {
  printf 'usage: ns resume <id> | ns resume --all\n\n'
  printf 'Restart a parked or stopped run, or one that crashed (state running, no tmux\n'
  printf 'session). --all resumes every non-archived parked or crashed run; a run stopped\n'
  printf 'by the owner (ns stop, ns kill) is resumed only by name.\n'
}

# ns_resume_rebuild <id> <entry-json>: recreate a missing run worktree
ns_resume_rebuild() {
  local id="$1" entry="$2" wt branch pname project path
  wt=$(jq -r .worktree <<<"$entry")
  branch=$(jq -r .branch <<<"$entry")
  pname=$(jq -r .project <<<"$entry")
  project=$(ns_project_by_name "$pname") || ns_die "cannot rebuild $id: project $pname is not registered"
  path=$(jq -r .path <<<"$project")
  git -C "$path" worktree prune
  git -C "$path" fetch -q origin "$branch" 2>/dev/null || true
  if git -C "$path" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
    git -C "$path" worktree add -q "$wt" "$branch" || ns_die "cannot rebuild $id: git worktree add failed"
  elif git -C "$path" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
    git -C "$path" worktree add -q -b "$branch" "$wt" "origin/$branch" || ns_die "cannot rebuild $id: git worktree add failed"
  else
    ns_die "cannot rebuild $id: branch $branch is on neither this machine nor origin"
  fi
}

# ns_resume_reconcile <id> <wt> <ledger> <entry-json>
ns_resume_reconcile() {
  local id="$1" wt="$2" ledger="$3" entry="$4" feature trailer project path log live phases ph st
  feature=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.feature_branch // ""') || return 1
  [ -n "$feature" ] || return 0
  git -C "$wt" fetch -q origin "$feature" 2>/dev/null || true
  trailer=Plan-Phase
  if project=$(ns_project_by_name "$(jq -r .project <<<"$entry")"); then
    path=$(jq -r .path <<<"$project")
    trailer=$(ns_profile_json "$path" 2>/dev/null | jq -r '.git.phase_trailer // "Plan-Phase"') || trailer=Plan-Phase
    [ -n "$trailer" ] || trailer=Plan-Phase
  fi
  log=$(git -C "$wt" log "origin/$feature" --format=%B 2>/dev/null) || log=""
  live=$(ns_pool_live "$id" | awk '{print $2}')
  phases=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.phases[] | [.id, .state] | @tsv') || return 1
  while IFS=$'\t' read -r ph st; do
    [ -n "$ph" ] || continue
    [ "$st" != merged ] || continue
    if grep -qxF "$trailer: $ph" <<<"$log"; then
      "$NS_HOME/bin/ns-ledger" set "$ledger" "(.phases[] | select(.id == \"$ph\") | .state) = \"merged\"" || return 1
      "$NS_HOME/bin/ns-ledger" event "$ledger" note "reconciled $ph as merged" || return 1
    elif [ "$st" = running ] && ! grep -qxF "$ph" <<<"$live"; then
      "$NS_HOME/bin/ns-ledger" set "$ledger" "(.phases[] | select(.id == \"$ph\") | .state) = \"pending\"" || return 1
      "$NS_HOME/bin/ns-ledger" event "$ledger" note "reconciled $ph as pending: no live worker" || return 1
    fi
  done <<<"$phases"
}

# ns_resume_push <id> <ledger>: commit the ledger and push it with the token of the run's
# project owner. The token is set only in this push's subshell: ns dequeue runs without one
# (ns-launch drops the ending run's token), and it must never reach a tmux server or another run.
# A caller's GH_TOKEN (another owner's, or an agent's) is dropped first; without a token file
# the push uses gh's own login, like the conductor sessions.
ns_resume_push() {
  local id="$1" ledger="$2"
  (
    local entry project repo
    unset GH_TOKEN
    if entry=$(ns_run_get "$id") && project=$(ns_project_by_name "$(jq -r .project <<<"$entry")"); then
      repo=$(jq -r .repo <<<"$project")
      ns_token_export "${repo%%/*}"
    fi
    exec "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push
  ) 9>&-
}

# ns_resume_dequeue_check <id> <ledger>: for ns dequeue, under the lock: returns 11 when the run no
# longer waits in the queue (another process took it, or it has a gate or a session), 10 when no
# slot is free, 0 when it may start
ns_resume_dequeue_check() {
  local id="$1" ledger="$2" cur
  cur=$("$NS_HOME/bin/ns-ledger" get "$ledger" '[.state, (.gate // "-"), (.queued_for_slot // false)] | @tsv') || return 11
  if [ "$cur" != "queued"$'\t'"-"$'\t'"true" ] || ns_tmux_has "$id"; then
    return 11
  fi
  [ "$(ns_queue_live_count)" -lt "$(ns_queue_max)" ] || return 10
}

# ns_resume_rollback <ledger> <state> <queued_for_slot>: a resume failed after the ledger was set
# to running; put back the state and the queue mark so the run is neither lost from the queue nor
# left running without a session. Best effort: the caller reports the failure.
ns_resume_rollback() {
  local ledger="$1" state="$2" mark="$3"
  [ "$mark" = true ] || mark=false
  "$NS_HOME/bin/ns-ledger" set "$ledger" ".state = $(jq -nc --arg s "$state" '$s') | .queued_for_slot = $mark" || return 0
  "$NS_HOME/bin/ns-ledger" event "$ledger" note "resume failed; back to $state" || true
  "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" 9>&- || true
}

# ns_resume_start <id> <wt> <ledger> <state> <rhome>: under the queue lock, start the conductor
# when a slot is free, else mark the run queued (returns 10). With NS_DEQUEUE=1 (ns dequeue) it
# starts the run only if it is still waiting in the queue: returns 10 when no slot is free (run
# left as is) and 11 when another process already took the run
ns_resume_start() {
  local id="$1" wt="$2" ledger="$3" state="$4" rhome="$5" live mark
  if [ "${NS_DEQUEUE:-}" = 1 ]; then
    ns_resume_dequeue_check "$id" "$ledger" || return
    state=queued
    mark=true
  else
    if ns_tmux_has "$id"; then
      printf '%s is already running\n' "$id"
      return 0
    fi
    live=$(ns_queue_live_count)
    if [ "$live" -ge "$(ns_queue_max)" ]; then
      if [ "$state" != queued ] || [ "$("$NS_HOME/bin/ns-ledger" get "$ledger" '.queued_for_slot // false')" != true ]; then
        "$NS_HOME/bin/ns-ledger" set "$ledger" '.stop_requested = null | .queued_for_slot = true' || return 1
        "$NS_HOME/bin/ns-ledger" state "$ledger" queued --note "waiting for a free run slot" || return 1
        "$NS_HOME/bin/ns-ledger" event "$ledger" queued "waiting for a free run slot" || return 1
        ns_resume_push "$id" "$ledger" || return 1
      fi
      ns_queue_msg "$id" "$live"
      return 10
    fi
    mark=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.queued_for_slot // false') || return 1
  fi
  # the budget clock restarts now: the gap since the last checkpoint (a crash, a park, the queue, a
  # stop) is not budget used (#9). ns-ledger set restarts it for any other state; a crashed run was
  # already running, so set since here too
  # shellcheck disable=SC2016 # $now is the jq variable of ns-ledger set
  "$NS_HOME/bin/ns-ledger" set "$ledger" '.stop_requested = null | .queued_for_slot = false | .state = "running" | .budget.since = $now' || return 1
  if ! "$NS_HOME/bin/ns-ledger" event "$ledger" resumed "resumed from $state" ||
    ! ns_resume_push "$id" "$ledger" ||
    ! NS_HOME="$rhome" ns_tmux_start "$id" "$wt" "$rhome/bin/ns-launch $id --resume"; then
    ns_resume_rollback "$ledger" "$state" "$mark"
    return 1
  fi
  printf 'resumed %s\n' "$id"
}

# ns_resume_one <id>: returns 10 when the run had to wait in the queue
ns_resume_one() {
  local id="$1" entry wt ledger state gate rhome
  entry=$(ns_run_get "$id") || ns_die "unknown run $id"
  wt=$(jq -r .worktree <<<"$entry")
  ledger=$(ns_run_ledger "$id")
  if [ ! -d "$wt" ]; then
    ns_resume_rebuild "$id" "$entry" || return 1
  fi
  [ -f "$ledger" ] || ns_die "cannot resume $id: no ledger at $ledger"
  if [ "${NS_DEQUEUE:-}" = 1 ]; then
    # queue membership is checked under the lock; no kill or reconcile on a run that may be live
    rhome=$(ns_release_home "$ledger") || return 1
    [ -n "$rhome" ] || rhome="$NS_HOME"
    ns_queue_locked ns_resume_start "$id" "$wt" "$ledger" queued "$rhome"
    return
  fi
  state=$("$NS_HOME/bin/ns-ledger" get "$ledger" .state) || return 1
  if [ "$state" = running ] && ns_tmux_has "$id"; then
    printf '%s is already running\n' "$id"
    return 0
  fi
  case "$state" in
    done | failed)
      printf '%s is %s; nothing to resume\n' "$id" "$state"
      return 0
      ;;
  esac
  gate=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.gate // ""')
  if [ -n "$gate" ]; then
    printf '%s waits for the owner at gate %s: edit the desk documents, then ns approve %s\n' "$id" "$gate" "$id"
    return 0
  fi
  rhome=$(ns_release_home "$ledger") || return 1
  [ -n "$rhome" ] || rhome="$NS_HOME"
  if ns_tmux_has "$id"; then
    ns_tmux_kill "$id" || return 1
  fi
  ns_resume_reconcile "$id" "$wt" "$ledger" "$entry" || return 1
  ns_queue_locked ns_resume_start "$id" "$wt" "$ledger" "$state" "$rhome"
}

ns_resume_main() {
  local u="ns resume <id> | ns resume --all"
  [ $# -eq 1 ] || ns_usage "$u"
  if [ "$1" = --all ]; then
    local id ledger state rc=0 n=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      ledger=$(ns_run_ledger "$id")
      state=""
      if [ -f "$ledger" ]; then
        state=$("$NS_HOME/bin/ns-ledger" get "$ledger" .state 2>/dev/null) || state=""
      fi
      case "$state" in
        parked | "") ;;
        stopped)
          # stopped by the owner (ns stop, ns kill) on purpose: only ns resume <id> restarts it
          printf '%s is stopped; resume it by name: ns resume %s\n' "$id" "$id"
          continue
          ;;
        running)
          if ns_tmux_has "$id"; then continue; fi
          ;;
        *) continue ;;
      esac
      n=$((n + 1))
      (ns_resume_one "$id") || [ $? -eq 10 ] || rc=1
    done < <(ns_runs_json | jq -r '.[] | select(.archived | not) | .id')
    [ "$n" -gt 0 ] || printf 'nothing to resume\n'
    return "$rc"
  fi
  [[ $1 != -* ]] || ns_usage "$u"
  ns_resume_one "$1" || [ $? -eq 10 ]
}

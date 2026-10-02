# shellcheck shell=bash
# summary: restart parked or stopped runs

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/pool.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/profile.sh"

ns_resume_help() {
  printf 'usage: ns resume <id> | ns resume --all\n\n'
  printf 'Restart a parked or stopped run, or one that crashed (state running, no tmux\n'
  printf 'session). --all resumes every such non-archived run.\n'
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
  local id="$1" wt="$2" ledger="$3" entry="$4" feature trailer project path log live ph st
  feature=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.feature_branch // ""')
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
  while IFS=$'\t' read -r ph st; do
    [ -n "$ph" ] || continue
    [ "$st" != merged ] || continue
    if grep -qxF "$trailer: $ph" <<<"$log"; then
      "$NS_HOME/bin/ns-ledger" set "$ledger" "(.phases[] | select(.id == \"$ph\") | .state) = \"merged\""
      "$NS_HOME/bin/ns-ledger" event "$ledger" note "reconciled $ph as merged"
    elif [ "$st" = running ] && ! grep -qxF "$ph" <<<"$live"; then
      "$NS_HOME/bin/ns-ledger" set "$ledger" "(.phases[] | select(.id == \"$ph\") | .state) = \"pending\""
      "$NS_HOME/bin/ns-ledger" event "$ledger" note "reconciled $ph as pending: no live worker"
    fi
  done < <("$NS_HOME/bin/ns-ledger" get "$ledger" '.phases[] | [.id, .state] | @tsv')
}

# ns_resume_one <id>
ns_resume_one() {
  local id="$1" entry wt ledger state gate
  entry=$(ns_run_get "$id") || ns_die "unknown run $id"
  wt=$(jq -r .worktree <<<"$entry")
  ledger=$(ns_run_ledger "$id")
  if [ ! -d "$wt" ]; then
    ns_resume_rebuild "$id" "$entry"
  fi
  [ -f "$ledger" ] || ns_die "cannot resume $id: no ledger at $ledger"
  state=$("$NS_HOME/bin/ns-ledger" get "$ledger" .state)
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
  if ns_tmux_has "$id"; then
    ns_tmux_kill "$id"
  fi
  ns_resume_reconcile "$id" "$wt" "$ledger" "$entry"
  "$NS_HOME/bin/ns-ledger" set "$ledger" '.stop_requested = null | .state = "running"'
  "$NS_HOME/bin/ns-ledger" event "$ledger" resumed "resumed from $state"
  "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push
  ns_tmux_start "$id" "$wt" "$NS_HOME/bin/ns-launch $id --resume"
  printf 'resumed %s\n' "$id"
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
        parked | stopped | "") ;;
        running)
          if ns_tmux_has "$id"; then continue; fi
          ;;
        *) continue ;;
      esac
      n=$((n + 1))
      (ns_resume_one "$id") || rc=1
    done < <(ns_runs_json | jq -r '.[] | select(.archived | not) | .id')
    [ "$n" -gt 0 ] || printf 'nothing to resume\n'
    return "$rc"
  fi
  [[ $1 != -* ]] || ns_usage "$u"
  ns_resume_one "$1"
}

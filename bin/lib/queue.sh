# shellcheck shell=bash
# Run queue: at most max_runs live conductors at once (R-CON-7).

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

# ns_queue_max: config max_runs, default 2
ns_queue_max() {
  local v
  v=$(ns_config_get max_runs 2)
  if ! [[ $v =~ ^[1-9][0-9]*$ ]]; then
    ns_warn "max_runs must be a positive integer, got '$v'; using 2"
    v=2
  fi
  printf '%s\n' "$v"
}

# ns_queue_live_count: non-archived runs with a live conductor tmux session.
# NS_QUEUE_EXCLUDE=<id> leaves that run out (the one that is just ending).
ns_queue_live_count() {
  local id n=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$id" != "${NS_QUEUE_EXCLUDE:-}" ] || continue
    if ns_tmux_has "$id"; then n=$((n + 1)); fi
  done < <(ns_runs_json | jq -r '.[] | select(.archived | not) | .id')
  printf '%s\n' "$n"
}

# ns_queue_locked <cmd...>: run the command holding the exclusive queue lock
ns_queue_locked() {
  mkdir -p "$(ns_config_dir)"
  (
    flock -w "${NS_QUEUE_LOCK_WAIT:-120}" 9 || ns_die "queue lock busy: $(ns_config_dir)/queue.lock"
    "$@"
  ) 9>>"$(ns_config_dir)/queue.lock"
}

# ns_queue_list: ids of runs that wait for a slot (state queued, queued_for_slot set under the
# lock, no gate, no live session), oldest first
ns_queue_list() {
  local id ledger st gate mark
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ledger=$(ns_run_ledger "$id") || continue
    [ -f "$ledger" ] || continue
    st=$("$NS_HOME/bin/ns-ledger" get "$ledger" '[.state, (.gate // "-"), (.queued_for_slot // false)] | @tsv' 2>/dev/null) || continue
    IFS=$'\t' read -r st gate mark <<<"$st"
    [ "$st" = queued ] && [ "$gate" = - ] && [ "$mark" = true ] || continue
    ! ns_tmux_has "$id" || continue
    printf '%s\n' "$id"
  done < <(ns_runs_json | jq -r '[.[] | select(.archived | not)] | sort_by(.created) | .[].id')
}

# ns_queue_msg <id> <live>: the line printed for a run that waits
ns_queue_msg() {
  printf 'queued %s: %s of %s runs active (starts when one finishes)\n' "$1" "$2" "$(ns_queue_max)"
}

# ns_queue_for_upgrade <id> <ledger> <state> [<push function>]: under the queue lock, when the
# upgrade lock was taken after the caller's first check: queue the run (ns dequeue starts it once
# the lock is gone). The push function (called with <id> <ledger>, as ns_resume_push) commits and
# pushes the ledger; without one it is ns-ledger checkpoint --push.
ns_queue_for_upgrade() {
  local id="$1" ledger="$2" state="$3" push="${4:-}"
  if [ "$state" != queued ] || [ "$("$NS_HOME/bin/ns-ledger" get "$ledger" '.queued_for_slot // false')" != true ]; then
    # no live conductor here: the gap since the last checkpoint is not budget used (#9)
    # shellcheck disable=SC2016 # $now is the jq variable of ns-ledger set
    "$NS_HOME/bin/ns-ledger" set "$ledger" '.stop_requested = null | .queued_for_slot = true | .budget.since = $now' || return 1
    "$NS_HOME/bin/ns-ledger" state "$ledger" queued --note "waiting for the upgrade to end" || return 1
    "$NS_HOME/bin/ns-ledger" event "$ledger" queued "waiting for the upgrade to end" || return 1
    if [ -n "$push" ]; then
      "$push" "$id" "$ledger" || return 1
    else
      "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push 9>&- || return 1
    fi
  fi
  printf 'queued %s: an upgrade is in progress (starts with ns dequeue when it ends)\n' "$id"
  return 10
}

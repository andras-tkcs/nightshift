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
  [[ $v =~ ^[0-9]+$ ]] || v=2
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
    flock 9
    "$@"
  ) 9>"$(ns_config_dir)/queue.lock"
}

# ns_queue_list: ids of queued runs (no gate, no live session), oldest first
ns_queue_list() {
  local id ledger st gate
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ledger=$(ns_run_ledger "$id") || continue
    [ -f "$ledger" ] || continue
    st=$("$NS_HOME/bin/ns-ledger" get "$ledger" '[.state, (.gate // "")] | @tsv' 2>/dev/null) || continue
    IFS=$'\t' read -r st gate <<<"$st"
    [ "$st" = queued ] && [ -z "$gate" ] || continue
    ! ns_tmux_has "$id" || continue
    printf '%s\n' "$id"
  done < <(ns_runs_json | jq -r '[.[] | select(.archived | not)] | sort_by(.created) | .[].id')
}

# ns_queue_msg <id> <live>: the line printed for a run that waits
ns_queue_msg() {
  printf 'queued %s: %s of %s runs active (starts when one finishes)\n' "$1" "$2" "$(ns_queue_max)"
}

# shellcheck shell=bash
# summary: park every run at its next checkpoint

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

ns_drain_help() {
  printf 'usage: ns drain [--timeout <s>]\n\n'
  printf 'Before a reboot: ask every running or queued run to park at its next checkpoint\n'
  printf 'and wait until none is running (default timeout 1800 s). Runs waiting at a gate\n'
  printf 'are left alone.\n'
}

# ns_drain_running: ids of non-archived runs whose ledger state is running
ns_drain_running() {
  local id ledger
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ledger=$(ns_run_ledger "$id")
    [ -f "$ledger" ] || continue
    if [ "$("$NS_HOME/bin/ns-ledger" get "$ledger" .state 2>/dev/null)" = running ]; then
      printf '%s\n' "$id"
    fi
  done < <(ns_runs_json | jq -r '.[] | select(.archived | not) | .id')
}

ns_drain_main() {
  local u="ns drain [--timeout <s>]" timeout=1800
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout)
        [ $# -ge 2 ] && [[ $2 =~ ^[0-9]+$ ]] || ns_usage "$u"
        timeout="$2"
        shift
        ;;
      *) ns_usage "$u" ;;
    esac
    shift
  done
  local id ledger state flagged=() poll="${NS_DRAIN_POLL:-10}"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ledger=$(ns_run_ledger "$id")
    [ -f "$ledger" ] || continue
    state=$("$NS_HOME/bin/ns-ledger" get "$ledger" .state 2>/dev/null) || continue
    case "$state" in
      running | queued) ;;
      *) continue ;;
    esac
    if ns_tmux_has "$id"; then
      # keep an owner's pending ns stop: a stopped run must not come back with ns resume --all
      "$NS_HOME/bin/ns-ledger" set "$ledger" '.stop_requested = (.stop_requested // "parked")'
      "$NS_HOME/bin/ns-ledger" event "$ledger" stop-requested "drain: park requested"
    else
      # no session: the time since the last checkpoint is a dead gap, not budget used (#9)
      # shellcheck disable=SC2016 # $now is the jq variable of ns-ledger set
      "$NS_HOME/bin/ns-ledger" set "$ledger" '.state="parked" | .budget.since = $now'
      "$NS_HOME/bin/ns-ledger" event "$ledger" parked "drain: parked, no session"
    fi
    "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" || true
    flagged+=("$id")
  done < <(ns_runs_json | jq -r '.[] | select(.archived | not) | .id')

  local start now left still
  start=$(date +%s)
  while :; do
    still=$(ns_drain_running | paste -sd' ' -)
    if [ -z "$still" ]; then
      printf 'parked: %s\n' "${flagged[*]:-}"
      return 0
    fi
    now=$(date +%s)
    left=$((timeout - (now - start)))
    if [ "$left" -le 0 ]; then
      printf 'still running: %s\n' "$still" >&2
      return 1
    fi
    if [ "$left" -lt "$poll" ]; then sleep "$left"; else sleep "$poll"; fi
  done
}

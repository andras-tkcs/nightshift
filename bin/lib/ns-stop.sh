# shellcheck shell=bash
# summary: stop a run at its next checkpoint (at once if idle)

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/ns-kill.sh"

ns_stop_help() {
  printf 'usage: ns stop <id>\n\n'
  printf 'Ask the run to stop at its next checkpoint (sets stop_requested in the ledger).\nA run with no live conductor session (at a gate, or dead) is stopped at once.\n'
}

ns_stop_main() {
  local u="ns stop <id>"
  [ $# -eq 1 ] && [[ $1 != -* ]] || ns_usage "$u"
  local id="$1" ledger state
  ns_run_get "$id" >/dev/null || ns_die "unknown run $id"
  ledger=$(ns_run_ledger "$id")
  [ -f "$ledger" ] || ns_die "no ledger for $id: worktree missing, try ns resume $id"
  state=$("$NS_HOME/bin/ns-ledger" get "$ledger" .state)
  case "$state" in
    stopped | parked | done | failed)
      printf '%s is already %s\n' "$id" "$state"
      return 0
      ;;
  esac
  if ! ns_tmux_has "$id"; then
    ns_kill_teardown "$id" "$ledger" "stopped by the owner (no live conductor)"
    printf '%s stopped (it had no live conductor)\n' "$id"
    return 0
  fi
  "$NS_HOME/bin/ns-ledger" set "$ledger" '.stop_requested="stopped"'
  "$NS_HOME/bin/ns-ledger" event "$ledger" stop-requested "stop requested by the owner"
  "$NS_HOME/bin/ns-ledger" checkpoint "$ledger"
  printf 'stop requested for %s; it stops at its next checkpoint\n' "$id"
}

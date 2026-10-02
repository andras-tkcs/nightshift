# shellcheck shell=bash
# summary: stop a run at its next checkpoint

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

ns_stop_help() {
  printf 'usage: ns stop <id>\n\n'
  printf 'Ask the run to stop at its next checkpoint (sets stop_requested in the ledger).\n'
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
  "$NS_HOME/bin/ns-ledger" set "$ledger" '.stop_requested="stopped"'
  "$NS_HOME/bin/ns-ledger" event "$ledger" stop-requested "stop requested by the owner"
  "$NS_HOME/bin/ns-ledger" checkpoint "$ledger"
  printf 'stop requested for %s; it stops at its next checkpoint\n' "$id"
}

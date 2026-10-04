# shellcheck shell=bash
# summary: notify about dead or silent runs (timer)

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

ns_health_check_help() {
  printf 'usage: ns health-check\n\n'
  printf 'Looks at every active run that is running with no open gate. A run whose tmux session is\n'
  printf 'gone is dead; one whose log has not grown for NS_SILENT_SECS (default 1200) is silent.\n'
  printf 'Each incident sends one ns-notify message; the incident is remembered in\n'
  printf '<config dir>/health/<id> and cleared when the run is healthy again. A systemd timer runs\n'
  printf 'this every 5 minutes.\n'
}

ns_health_check_main() {
  [ $# -eq 0 ] || ns_usage "ns health-check"
  ns_load_env
  local entry id ledger led state gate health dir bad=0 sent=0 total=0
  dir="$(ns_config_dir)/health"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    id=$(jq -r .id <<<"$entry")
    ledger=$(ns_run_ledger "$id") || continue
    [ -f "$ledger" ] || continue
    led=$("$NS_HOME/bin/ns-ledger" get "$ledger" 2>/dev/null) || continue
    total=$((total + 1))
    state=$(jq -r '.state // ""' <<<"$led")
    gate=$(jq -r '.gate // ""' <<<"$led")
    health=$(ns_run_health "$id" "$state" "$gate")
    if [ "$health" = ok ]; then
      rm -f "$dir/$id"
      continue
    fi
    bad=$((bad + 1))
    [ ! -e "$dir/$id" ] || continue
    mkdir -p "$dir"
    printf '%s\n' "$health" >"$dir/$id"
    "$NS_HOME/bin/ns-notify" "ns: $id is $health (see ns status $id)" || ns_warn "could not send the notification"
    sent=$((sent + 1))
  done < <(ns_runs_json | jq -c '.[] | select(.archived | not)')
  printf 'ns health-check: %s run(s) checked, %s unhealthy, %s notified\n' "$total" "$bad" "$sent"
}

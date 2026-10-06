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
  printf 'Each incident sends one ns-notify message (another when it changes between dead and silent); the incident is remembered in\n'
  printf '<config dir>/health/<id> and cleared when the run is healthy again. A systemd timer runs\n'
  printf 'this every 5 minutes.\n\n'
  printf 'It also resumes (ns resume) a run that was parked on a usage limit once the\n'
  printf 'budget.paused_until time in its ledger has passed.\n'
}

ns_health_check_main() {
  [ $# -eq 0 ] || ns_usage "ns health-check"
  ns_load_env
  local entry id ledger led state gate health dir f old bad=0 sent=0 total=0 seen=' ' pu now
  local wake=() resumed=0
  dir="$(ns_config_dir)/health"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    id=$(jq -r .id <<<"$entry")
    ledger=$(ns_run_ledger "$id") || continue
    [ -f "$ledger" ] || continue
    led=$("$NS_HOME/bin/ns-ledger" get "$ledger" 2>/dev/null) || continue
    total=$((total + 1))
    seen="$seen$id "
    state=$(jq -r '.state // ""' <<<"$led")
    gate=$(jq -r '.gate // ""' <<<"$led")
    pu=$(jq -r 'if .state == "parked" and .budget.paused then (.budget.paused_until // "") else "" end' <<<"$led")
    if [ -n "$pu" ]; then
      now=$(date -u -d "$(ns_now)" +%s)
      [ "$(date -u -d "$pu" +%s)" -gt "$now" ] || wake+=("$id")
    fi
    health=$(ns_run_health "$id" "$state" "$gate")
    if [ "$health" = ok ]; then
      rm -f "$dir/$id"
      continue
    fi
    bad=$((bad + 1))
    if [ -e "$dir/$id" ]; then
      old=$(cat "$dir/$id")
      # same class (dead vs silent) stays quiet; silent <N>m vs <M>m is the same incident
      [ "${old%% *}" != "${health%% *}" ] || continue
    fi
    mkdir -p "$dir"
    printf '%s\n' "$health" >"$dir/$id"
    "$NS_HOME/bin/ns-notify" "ns: $id is $health (see ns status $id)" || ns_warn "could not send the notification"
    sent=$((sent + 1))
  done < <(ns_runs_json | jq -c '.[] | select(.archived | not)')
  if [ -d "$dir" ]; then
    for f in "$dir"/*; do
      [ -e "$f" ] || continue
      id=${f##*/}
      case "$seen" in *" $id "*) ;; *) rm -f "$f" ;; esac
    done
  fi
  for id in "${wake[@]}"; do
    # parked on a usage limit that has reset: resume (ns resume queues it when no slot is free)
    if "$NS_HOME/bin/ns" resume "$id"; then
      resumed=$((resumed + 1))
    else
      ns_warn "could not resume $id after its usage limit"
    fi
  done
  "$NS_HOME/bin/ns" dequeue >/dev/null || ns_warn "ns dequeue failed"
  printf 'ns health-check: %s run(s) checked, %s unhealthy, %s notified, %s resumed after a usage limit\n' "$total" "$bad" "$sent" "$resumed"
}

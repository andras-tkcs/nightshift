# shellcheck shell=bash
# summary: notify about dead or silent runs (timer)

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

ns_health_check_help() {
  printf 'usage: ns health-check\n\n'
  printf 'Looks at every active run that is running with no open gate. A run whose tmux session is\n'
  printf 'gone is dead; one whose logs (JSONL, checks log) have not grown for NS_SILENT_SECS (default\n'
  printf '1200) is silent, unless its conductor is running ns-conductor checks.\n'
  printf 'Each incident sends one ns-notify message (another when it changes between dead and silent); the incident is remembered in\n'
  printf '<config dir>/health/<id> and cleared when the run is healthy again. A systemd timer runs\n'
  printf 'this every 5 minutes.\n\n'
  printf 'After ns dequeue it resumes (ns resume) a run paused on a usage limit, parked or with a\n'
  printf 'dead conductor and no open gate, once budget.paused_until in its ledger has passed.\n'
}

ns_health_check_main() {
  [ $# -eq 0 ] || ns_usage "ns health-check"
  ns_load_env
  local entry id ledger led state gate health dir f old bad=0 sent=0 total=0 seen=' ' pu now
  local wake=() resumed=0 queued=0 out
  dir="$(ns_config_dir)/health"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    id=$(jq -r .id <<<"$entry")
    # seen first: a tick that cannot read the ledger must keep the incident, or the next one notifies again
    seen="$seen$id "
    ledger=$(ns_run_ledger "$id") || continue
    [ -f "$ledger" ] || continue
    led=$("$NS_HOME/bin/ns-ledger" get "$ledger" 2>/dev/null) || continue
    total=$((total + 1))
    state=$(jq -r '.state // ""' <<<"$led")
    gate=$(jq -r '.gate // ""' <<<"$led")
    health=$(ns_run_health "$id" "$state" "$gate")
    # paused on a usage limit, no open gate, and parked (or its conductor died): wake after the reset
    pu=$(jq -r 'if .gate == null and .budget.paused and (.state == "parked" or .state == "running") then (.budget.paused_until // "") else "" end' <<<"$led")
    if [ -n "$pu" ] && { [ "$state" = parked ] || [ "$health" = dead ]; }; then
      now=$(date -u -d "$(ns_now)" +%s)
      [ "$(date -u -d "$pu" +%s)" -gt "$now" ] || wake+=("$id")
    fi
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
  # queued runs first, so they keep their place ahead of runs woken from a usage limit
  "$NS_HOME/bin/ns" dequeue >/dev/null || ns_warn "ns dequeue failed"
  for id in "${wake[@]}"; do
    # the usage limit has reset: resume (ns resume queues it when no run slot is free)
    if out=$("$NS_HOME/bin/ns" resume "$id"); then
      [ -z "$out" ] || printf '%s\n' "$out"
      case "$out" in
        queued*) queued=$((queued + 1)) ;;
        *) resumed=$((resumed + 1)) ;;
      esac
    else
      [ -z "$out" ] || printf '%s\n' "$out"
      ns_warn "could not resume $id after its usage limit"
    fi
  done
  printf 'ns health-check: %s run(s) checked, %s unhealthy, %s notified, %s resumed after a usage limit, %s queued\n' "$total" "$bad" "$sent" "$resumed" "$queued"
}

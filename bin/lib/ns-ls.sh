# shellcheck shell=bash
# summary: list runs

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

ns_ls_help() {
  printf 'usage: ns ls [--all] [--json]\n\n'
  printf 'List the runs in the runs index, oldest first. --all includes archived runs.\n'
  printf '--json prints an array of {id, project, tier, state, gate, step, phases, created, health,\nelapsed_s, idle_s}.\n'
}

ns_ls_main() {
  local u="ns ls [--all] [--json]" all=false json=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=true ;;
      --json) json=true ;;
      *) ns_usage "$u" ;;
    esac
    shift
  done
  local runs rows="[]" entry id wt ledger led row health idle created elapsed t0
  runs=$(ns_runs_json | jq -c --argjson all "$all" '[.[] | select($all or (.archived | not))] | sort_by(.created)')
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    id=$(jq -r .id <<<"$entry")
    wt=$(jq -r .worktree <<<"$entry")
    ledger="$wt/.nightshift/runs/$id/ledger.yaml"
    led=""
    if [ -d "$wt" ] && [ -f "$ledger" ]; then
      led=$("$NS_HOME/bin/ns-ledger" get "$ledger" 2>/dev/null) || led=""
    fi
    if [ -n "$led" ]; then
      row=$(jq -c --argjson e "$entry" '{id: $e.id, project: $e.project, tier, state, gate, step,
        phases: [.phases[]? | select(.state == "running" or .state == "review") | .id],
        queued: any(.phases[]?; .state == "queued"), created: $e.created}' <<<"$led")
    else
      row=$(jq -c '{id, project, tier: null, state: "?", gate: null, step: null, phases: [], queued: false,
        missing: true, created}' <<<"$entry")
    fi
    if [ "$(jq -r '.state' <<<"$row")" = queued ] && ! ns_tmux_has "$id"; then
      row=$(jq -c '. + {waiting: true}' <<<"$row")
    fi
    health=$(ns_run_health "$id" "$(jq -r '.state' <<<"$row")" "$(jq -r '.gate // ""' <<<"$row")")
    idle=$(ns_run_idle_s "$id")
    created=$(jq -r .created <<<"$row")
    t0=$(date -u -d "$created" +%s 2>/dev/null) || t0=""
    elapsed=0
    if [ -n "$t0" ]; then elapsed=$(($(date -u -d "$(ns_now)" +%s) - t0)); fi
    [ "$elapsed" -ge 0 ] || elapsed=0
    row=$(jq -c --arg h "$health" --argjson el "$elapsed" --arg idle "$idle" \
      '. + {health: $h, elapsed_s: $el, idle_s: (if $idle == "" then null else ($idle | tonumber) end)}' <<<"$row")
    rows=$(jq -c --argjson r "$row" '. + [$r]' <<<"$rows")
  done < <(jq -c '.[]' <<<"$runs")

  if [ "$json" = true ]; then
    jq 'map(del(.queued, .missing, .waiting))' <<<"$rows"
    return 0
  fi
  if [ "$(jq length <<<"$rows")" = 0 ]; then
    printf 'no runs\n'
    return 0
  fi
  printf '%-14s %-4s %-18s %-11s %-14s %-7s %-8s %s\n' ID TIER PHASE STATE WAITING-ON AGE ELAPSED LAST-OUT
  local tier phase state wait age el last
  while IFS= read -r row; do
    id=$(jq -r .id <<<"$row")
    tier=$(jq -r '.tier // "-"' <<<"$row")
    state=$(jq -r .state <<<"$row")
    phase=$(jq -r 'if (.phases | length) > 0 then (.phases | join(",")) else (.step // "-") end' <<<"$row")
    wait=$(jq -r 'if .missing then "no-worktree" elif .gate != null then "owner:gate" + .gate elif .queued then "pool" elif .state == "queued" and .waiting then "runs" else "-" end' <<<"$row")
    health=$(jq -r .health <<<"$row")
    [ "$health" = ok ] || state=$health
    el=$(ns_secs_fmt "$(jq -r .elapsed_s <<<"$row")")
    last=$(jq -r 'if .idle_s == null then "-" else (.idle_s | tostring) end' <<<"$row")
    if [ "$last" != "-" ]; then last=$(ns_secs_fmt "$last"); fi
    age=$(ns_age "$(jq -r .created <<<"$row")" 2>/dev/null) || age="-"
    printf '%-14s %-4s %-18s %-11s %-14s %-7s %-8s %s\n' "$id" "$tier" "$phase" "$state" "$wait" "$age" "$el" "$last"
  done < <(jq -c '.[]' <<<"$rows")
}

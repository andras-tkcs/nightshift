# shellcheck shell=bash
# summary: list runs

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

ns_ls_help() {
  printf 'usage: ns ls [--all] [--json]\n\n'
  printf 'List the runs in the runs index, oldest first. --all includes archived runs.\n'
  printf '--json prints an array of {id, project, tier, state, gate, step, phases, created}.\n'
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
  local runs rows="[]" entry id wt ledger led row
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
    rows=$(jq -c --argjson r "$row" '. + [$r]' <<<"$rows")
  done < <(jq -c '.[]' <<<"$runs")

  if [ "$json" = true ]; then
    jq 'map(del(.queued, .missing))' <<<"$rows"
    return 0
  fi
  if [ "$(jq length <<<"$rows")" = 0 ]; then
    printf 'no runs\n'
    return 0
  fi
  printf '%-14s %-4s %-18s %-8s %-14s %s\n' ID TIER PHASE STATE WAITING-ON AGE
  local tier phase state wait age
  while IFS= read -r row; do
    id=$(jq -r .id <<<"$row")
    tier=$(jq -r '.tier // "-"' <<<"$row")
    state=$(jq -r .state <<<"$row")
    phase=$(jq -r 'if (.phases | length) > 0 then (.phases | join(",")) else (.step // "-") end' <<<"$row")
    wait=$(jq -r 'if .missing then "no-worktree" elif .gate != null then "owner:gate" + .gate elif .queued then "pool" else "-" end' <<<"$row")
    age=$(ns_age "$(jq -r .created <<<"$row")" 2>/dev/null) || age="-"
    printf '%-14s %-4s %-18s %-8s %-14s %s\n' "$id" "$tier" "$phase" "$state" "$wait" "$age"
  done < <(jq -c '.[]' <<<"$rows")
}

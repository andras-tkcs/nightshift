# shellcheck shell=bash
# summary: show a run's ledger

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/queue.sh"

ns_status_help() {
  printf 'usage: ns status <id> [--json]\n\n'
  printf "Show a run's tier, state, budget, branches, phases and last events.\n"
  printf '--json prints the whole ledger.\n'
}

ns_status_main() {
  local u="ns status <id> [--json]" id="" json=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=true ;;
      -*) ns_usage "$u" ;;
      *)
        [ -z "$id" ] || ns_usage "$u"
        id="$1"
        ;;
    esac
    shift
  done
  [ -n "$id" ] || ns_usage "$u"
  ns_run_get "$id" >/dev/null || ns_die "unknown run $id"
  local ledger led
  ledger=$(ns_run_ledger "$id")
  [ -f "$ledger" ] || ns_die "no ledger for $id: worktree missing, try ns resume $id"
  led=$("$NS_HOME/bin/ns-ledger" get "$ledger") || exit 1
  if [ "$json" = true ]; then
    printf '%s\n' "$led"
    return 0
  fi
  local health question="" esc
  if [ "$(jq -r '.gate // ""' <<<"$led")" = 1.5 ]; then
    esc="$(jq -r .worktree <<<"$(ns_run_get "$id")")/.nightshift/runs/$id/escalation.md"
    [ ! -f "$esc" ] || question=$(ns_escalation_question "$esc")
  fi
  local qline="" qlist qpos
  if [ "$(jq -r .state <<<"$led")" = queued ]; then
    qlist=$(ns_queue_list)
    qpos=$(grep -nxF "$id" <<<"$qlist" | cut -d: -f1 | head -1) || qpos=""
    if [ -n "$qpos" ]; then qline="position $qpos of $(grep -c . <<<"$qlist")"; fi
  fi
  health=$(ns_run_health "$id" "$(jq -r .state <<<"$led")" "$(jq -r '.gate // ""' <<<"$led")")
  jq -r --arg qline "$qline" --arg health "$health" --arg question "$question" '
    def pad($n): . + (" " * ([$n - length, 0] | max));
    "run      \(.id) (\(.project))",
    "tier     \(.tier // "-") (\(.tier_source // "-")\(if .tier_recommended then "; triage recommended " + .tier_recommended else "" end))",
    "state    \(.state) · gate \(.gate // "-") · step \(.step)",
    "health   \($health)",
    (if $qline != "" then "queue    \($qline)" else empty end),
    "release  \(.release // "-")",
    (if $question != "" then "question \($question)" else empty end),
    "budget   \(.budget.used) h of \(if .budget.limit == null then "-" else (.budget.limit | tostring) end) h",
    (if .stacked_on then "stacked  \(.stacked_on)" else empty end),
    "branches \(.branch) · \(.feature_branch // "-") · pr \(.pr // "-")",
    "phases",
    (.events as $ev
      | .phases[] | . as $p
      | "  \(.id | pad(8))  \(.state | pad(9)) \(.branch // "-")  attempts \(.attempts)  rounds \(.review_rounds)"
        + (if .review_verdict then "  review \(.review_verdict) \(.reviewed_head // "-" | .[0:12])" else "" end)
        + (if any($ev[]; .type == "report-rerun" and (.note | split(" ")[0]) == $p.id) then "  report regenerated" else "" end)),
    "events (last 5)",
    (.events[-5:][] | "  \(.time)  \(.type)  \(.note)")' <<<"$led"
}

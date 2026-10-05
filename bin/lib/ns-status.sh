# shellcheck shell=bash
# summary: show a run's ledger

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

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
  local health
  health=$(ns_run_health "$id" "$(jq -r .state <<<"$led")" "$(jq -r '.gate // ""' <<<"$led")")
  jq -r --arg health "$health" '
    def pad($n): . + (" " * ([$n - length, 0] | max));
    "run      \(.id) (\(.project))",
    "tier     \(.tier // "-") (\(.tier_source // "-")\(if .tier_recommended then "; triage recommended " + .tier_recommended else "" end))",
    "state    \(.state) · gate \(.gate // "-") · step \(.step)",
    "health   \($health)",
    "release  \(.release // "-")",
    "budget   \(.budget.used) h of \(if .budget.limit == null then "-" else (.budget.limit | tostring) end) h",
    "branches \(.branch) · \(.feature_branch // "-") · pr \(.pr // "-")",
    "phases",
    (.phases[] | "  \(.id | pad(8))  \(.state | pad(9)) \(.branch // "-")  attempts \(.attempts)  rounds \(.review_rounds)"),
    "events (last 5)",
    (.events[-5:][] | "  \(.time)  \(.type)  \(.note)")' <<<"$led"
}

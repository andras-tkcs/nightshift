# shellcheck shell=bash
# summary: send a running run an instruction it reads at its next checkpoint

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

ns_note_help() {
  printf 'usage: ns note <id> "text"\n\n'
  printf "Send the run an instruction. It is added to owner_notes in the ledger, committed and pushed;\n"
  printf "the conductor reads it at its next checkpoint and follows it over the plan's scope.\n"
  printf 'A note never releases a gate, lifts the guard or allows edits to protected paths.\n'
}

ns_note_main() {
  local u='ns note <id> "text"' id ledger text t n
  [ $# -eq 2 ] && [[ $1 != -* ]] || ns_usage "$u"
  id=$1 text=$2
  [[ -n ${text//[[:space:]]/} ]] || ns_usage "$u"
  ns_run_get "$id" >/dev/null || ns_die "unknown run $id"
  ledger=$(ns_run_ledger "$id")
  [ -f "$ledger" ] || ns_die "no ledger for $id: worktree missing, try ns resume $id"
  # a JSON string is a valid jq string literal; \( is encoded as \\(, so nothing is interpolated
  t=$(jq -cn --arg t "$text" '$t')
  # shellcheck disable=SC2016 # $now is a jq variable
  "$NS_HOME/bin/ns-ledger" set "$ledger" '.owner_notes = ((.owner_notes // []) + [{time: $now, text: '"$t"', read: false}])'
  n=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.owner_notes | length')
  "$NS_HOME/bin/ns-ledger" event "$ledger" owner-note "owner note $n added"
  "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push
  printf 'note %s sent to %s; it is read at the next checkpoint\n' "$n" "$id"
}

# shellcheck shell=bash
# t3: two independent phases run in parallel, tier T3 (see docs/development.md, "End-to-end runs")

E2E_TIMEOUT=14400

# the first two phases have overlapping phase-start/phase-end intervals
# shellcheck disable=SC2016  # a jq program: the $ are jq variables
T3_OVERLAP='
def t($ty; $p): [.events[] | select(.type == $ty and (.note | contains($p))) | .time];
[.phases[].id] as $ids
| ($ids | length) >= 2
  and ($ids[0] as $a | $ids[1] as $b
    | (t("phase-start"; $a) | min) as $sa | (t("phase-end"; $a) | max) as $ea
    | (t("phase-start"; $b) | min) as $sb | (t("phase-end"; $b) | max) as $eb
    | $sa != null and $sb != null and $ea != null and $eb != null
      and $sa < $eb and $sb < $ea)'

scenario_main() {
  e2e_new_run "$E2E_PREFIX" "Add two independent functions, each with tests and a README line: word_count(text) in sandbox_pkg/text.py and clamp(value, low, high) in sandbox_pkg/numbers.py. Plan them as two phases that do not depend on each other." --tier T3 --yes || return 1
  e2e_wait "$E2E_ID" '.gate == "1"' "$E2E_TIMEOUT" || return 1
  e2e_assert "triage recommendation is in the ledger" e2e_triage_recorded "$E2E_ID" || return 1
  e2e_approve "$E2E_ID" || return 1
  e2e_wait "$E2E_ID" '.state == "done"' "$E2E_TIMEOUT" || return 1
  e2e_assert "two phases ran with overlapping intervals" e2e_ledger_has "$E2E_ID" "$T3_OVERLAP" || return 1
  e2e_assert "each Plan-Phase trailer appears exactly once" e2e_each_trailer_once "$E2E_ID" || return 1
  e2e_assert "ledger has the review board event" e2e_ledger_has "$E2E_ID" 'any(.events[]; .type == "review" and (.note | contains("review board")))' || return 1
  e2e_assert "handoff.html is on the desk" test -f "$(e2e_desk_dir "$E2E_ID")/handoff.html" || return 1
  e2e_assert "PR is open against the base" e2e_pr_open_against_base "$E2E_ID" || return 1
  e2e_assert "PR checks are green" e2e_pr_checks_green "$E2E_ID" 20 || return 1
}

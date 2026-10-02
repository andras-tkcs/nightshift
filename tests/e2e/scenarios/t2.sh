# shellcheck shell=bash
# t2: a small feature with a plan gate, tier T2 (see docs/development.md, "End-to-end runs")

E2E_TIMEOUT=10800

scenario_main() {
  e2e_new_run "$E2E_PREFIX" "Add slugify(text) to sandbox_pkg/text.py: lowercase, spaces and punctuation become single hyphens, no leading or trailing hyphen. Add tests and a README section." --tier T2 --yes || return 1
  e2e_wait "$E2E_ID" '.gate == "1"' "$E2E_TIMEOUT" || return 1
  e2e_assert "triage recommendation is in the ledger" e2e_triage_recorded "$E2E_ID" || return 1
  e2e_approve "$E2E_ID" || return 1
  e2e_wait "$E2E_ID" '.state == "done"' "$E2E_TIMEOUT" || return 1
  e2e_assert "handoff.html is on the desk" test -f "$(e2e_desk_dir "$E2E_ID")/handoff.html" || return 1
  e2e_assert "PR is open against the base" e2e_pr_open_against_base "$E2E_ID" || return 1
  e2e_assert "PR checks are green" e2e_pr_checks_green "$E2E_ID" 20 || return 1
}

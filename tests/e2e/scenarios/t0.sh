# shellcheck shell=bash
# t0: a typo fix in README.md, tier T0 (docs/build-a-plan.md, D20)

E2E_TIMEOUT=2700

scenario_main() {
  e2e_new_run "$E2E_PREFIX" "Fix the typo 'recieve' in README.md" --tier T0 --yes || return 1
  e2e_wait "$E2E_ID" '.state == "done"' "$E2E_TIMEOUT" || return 1
  e2e_assert "triage recommendation is in the ledger" e2e_triage_recorded "$E2E_ID" || return 1
  e2e_assert "PR is open against the base" e2e_pr_open_against_base "$E2E_ID" || return 1
  e2e_assert "PR checks are green" e2e_pr_checks_green "$E2E_ID" 20 || return 1
  e2e_assert "budget used is within the limit" e2e_budget_within_limit "$E2E_ID" || return 1
  e2e_assert "README on the PR branch has 'receive'" t0_readme_fixed || return 1
}

t0_readme_fixed() {
  local text
  text=$(e2e_pr_file "$E2E_ID" README.md) || return 1
  grep -q 'receive' <<<"$text" && ! grep -q 'recieve' <<<"$text"
}

# shellcheck shell=bash
# stack: two T0 runs in a row; the second PR is stacked on the first (see docs/development.md,
# "End-to-end runs"). Not run by the bats suite; ns-main only.

E2E_TIMEOUT=2700

scenario_main() {
  local first second third leftovers
  leftovers=$(gh pr list --repo "$E2E_REPO" --state open --json headRefName --jq '.[].headRefName' | grep -E '^(fix|feature)/' || true)
  if [ -n "$leftovers" ]; then
    e2e_log "open run PRs left in the sandbox, close them first: $(tr '\n' ' ' <<<"$leftovers")"
    return 1
  fi
  e2e_new_run "$E2E_PREFIX" "Fix the typo 'recieve' in README.md" --tier T0 --yes || return 1
  first="$E2E_ID"
  e2e_wait "$first" '.state == "done"' "$E2E_TIMEOUT" || return 1
  e2e_assert "first PR is open against the base" e2e_pr_open_against_base "$first" || return 1

  e2e_new_run "$E2E_PREFIX" "Add a file NOTES.md that contains the line 'second run'" --tier T0 --yes || return 1
  second="$E2E_ID"
  e2e_wait "$second" '.state == "done"' "$E2E_TIMEOUT" || return 1
  e2e_assert "second run is stacked on the first" e2e_ledger_has "$second" ".stacked_on == \"$first\"" || return 1
  e2e_assert "second PR is based on the first PR's branch" stack_base_is_first "$first" "$second" || return 1
  e2e_assert "second PR's diff shows only its own change" stack_diff_is_own "$second" || return 1

  e2e_new_run "$E2E_PREFIX" "Add a file THIRD.md that contains the line 'third run'" --tier T0 --yes || return 1
  third="$E2E_ID"
  e2e_wait "$third" '.state == "done"' "$E2E_TIMEOUT" || return 1
  e2e_assert "third PR is based on the second PR's branch" stack_base_is_first "$second" "$third" || return 1

  # land the stack with one command (the sandbox PRs need an approval first, so this needs the owner's review)
  e2e_assert "ns stack merge lands all three PRs" stack_merge_all "$first" "$second" "$third" || return 1
}

stack_merge_all() {
  local id
  ns stack merge "$E2E_PREFIX" || return 1
  for id in "$@"; do
    [ "$(e2e_pr_json "$id" state | jq -r '.state')" = MERGED ] || return 1
  done
}

stack_base_is_first() {
  local want got
  want=$(e2e_pr_head_branch "$1") || return 1
  got=$(e2e_pr_json "$2" baseRefName | jq -r '.baseRefName') || return 1
  [ -n "$want" ] && [ "$want" = "$got" ]
}

stack_diff_is_own() {
  local files
  files=$(gh pr diff "$(e2e_pr_url "$1")" -R "$E2E_REPO" --name-only) || return 1
  [ "$files" = NOTES.md ]
}

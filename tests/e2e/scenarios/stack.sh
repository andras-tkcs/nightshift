# shellcheck shell=bash
# stack: two T0 runs in a row; the second PR is stacked on the first (see docs/development.md,
# "End-to-end runs"). Not run by the bats suite; ns-main only.

E2E_TIMEOUT=2700

scenario_main() {
  local first second third leftovers plans open prof pats
  # leftovers: open run PRs whose chain belongs to this scenario's base branch, by the rules of
  # bin/lib/stack-pr.sh (ns_stack_run_id with the scenario profile's branch patterns, a plan/<run id> branch
  # on origin, ns_stack_on_base): run PRs of other base branches (earlier e2e runs) are left alone.
  plans=$(gh api --paginate "repos/$E2E_REPO/git/matching-refs/heads/plan/" --jq '.[].ref | sub("refs/heads/plan/"; "")') || {
    e2e_log "could not list the plan branches of $E2E_REPO"
    return 1
  }
  open=$(gh api --paginate "repos/$E2E_REPO/pulls?state=open&per_page=100" \
    --jq '.[] | {number, head: .head.ref, base: .base.ref, createdAt: .created_at}') || {
    e2e_log "could not list the open PRs of $E2E_REPO"
    return 1
  }
  open=$(jq -sc . <<<"$open")
  prof="$(mktemp "${TMPDIR:-/tmp}/e2e-prof.XXXXXX")"
  e2e_render_profile "$E2E_BASE" "$prof"
  pats=$(python3 "$E2E_REPO_ROOT/bin/lib/profile.py" show "$prof" | jq -r '.git.fix_branch, .git.feature_branch') || {
    rm -f "$prof"
    e2e_log "could not read the scenario profile"
    return 1
  }
  rm -f "$prof"
  leftovers=$(stack_leftovers "$open" "$plans" "$E2E_BASE" "$E2E_PREFIX" "$(sed -n 1p <<<"$pats")" "$(sed -n 2p <<<"$pats")" "$E2E_REPO")
  if [ -n "$leftovers" ]; then
    e2e_log "open run PRs left on $E2E_BASE in the sandbox, close them first: $leftovers"
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
  e2e_assert "second PR's diff shows only its own change" stack_diff_is_own "$first" "$second" || return 1

  e2e_new_run "$E2E_PREFIX" "Add a file THIRD.md that contains the line 'third run'" --tier T0 --yes || return 1
  third="$E2E_ID"
  e2e_wait "$third" '.state == "done"' "$E2E_TIMEOUT" || return 1
  e2e_assert "third PR is based on the second PR's branch" stack_base_is_first "$second" "$third" || return 1

  # land the stack with one command; the owner has to approve the three PRs first
  e2e_log "approve the three PRs now: $(stack_pr_urls "$first" "$second" "$third")"
  e2e_assert "the owner approved all three PRs (waiting up to ${E2E_APPROVE_TIMEOUT}s)" stack_wait_approved "$first" "$second" "$third" || return 1
  e2e_assert "ns stack merge lands all three PRs" stack_merge_all "$first" "$second" "$third" || return 1
  e2e_assert "the checks on the base branch are green" stack_main_green || return 1
}

E2E_APPROVE_TIMEOUT=${E2E_APPROVE_TIMEOUT:-1800}

# stack_leftovers <open prs json [{number, head, base, createdAt}]> <plan run ids, one per line> <base branch>
# <prefix> <fix pattern> <feature pattern> [repo] [closed list json]: print the heads of the open run PRs whose
# chain belongs to the base branch, with the library's own rules: a run PR has a head matching a pattern
# (ns_stack_run_id) and a plan/<run id> branch; ns_stack_on_base keeps the chains on the base branch and
# those whose base cannot be told (conservative: they count as leftovers). The closed list is fetched from
# the repo when needed and not given.
stack_leftovers() {
  local open="$1" plans="$2" base="$3" prefix="$4" fixpat="$5" featpat="$6" repo="${7:-}" closed="${8:-}" rows="[]" row h rid
  # shellcheck source=/dev/null
  source "${E2E_REPO_ROOT:-$NS_HOME}/bin/lib/stack-pr.sh"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    h=$(jq -r .head <<<"$row")
    rid=$(ns_stack_run_id "$fixpat" "$featpat" "$prefix" "$h") || continue
    grep -qxF -- "$rid" <<<"$plans" || continue
    rows=$(jq -c --argjson r "$row" --arg rid "$rid" '. + [$r + {run: $rid, statusCheckRollup: []}]' <<<"$rows")
  done < <(jq -c '.[]' <<<"$open")
  ns_stack_on_base "$rows" "$base" "$fixpat" "$featpat" "$prefix" "$repo" "$closed" | jq -r '[.[].head] | join(" ")'
}

# stack_wait_approved <id>...: poll until every PR has reviewDecision APPROVED, or time out
stack_wait_approved() {
  local start id ok
  start=$(date +%s)
  while :; do
    ok=1
    for id in "$@"; do
      [ "$(e2e_pr_json "$id" reviewDecision | jq -r '.reviewDecision')" = APPROVED ] || ok=0
    done
    [ "$ok" -eq 0 ] || return 0
    [ $(($(date +%s) - start)) -lt "$E2E_APPROVE_TIMEOUT" ] || return 1
    sleep 30
  done
}

# stack_main_green: the checks of the base branch's head commit pass (no failing runs, none pending)
stack_main_green() {
  local sha n
  sleep 20
  sha=$(gh api "repos/$E2E_REPO/commits/$E2E_BASE" --jq .sha) || return 1
  # shellcheck disable=SC2016
  timeout 1200 bash -c 'until [ "$(gh api "repos/$0/commits/$1/status" --jq "[.statuses[] | select(.state == \"pending\")] | length")" = 0 ] \
    && [ "$(gh api "repos/$0/commits/$1/check-runs" --jq ".total_count")" -gt 0 ] \
    && ! gh api "repos/$0/commits/$1/check-runs" --jq ".check_runs[] | select(.status != \"completed\")" | grep -q .; do sleep 20; done' "$E2E_REPO" "$sha" || return 1
  n=$(gh api "repos/$E2E_REPO/commits/$sha/check-runs" --jq '[.check_runs[] | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral")] | length') || return 1
  [ "$n" -eq 0 ] && [ "$(gh api "repos/$E2E_REPO/commits/$sha/status" --jq '[.statuses[] | select(.state == "failure" or .state == "error")] | length')" = 0 ]
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

# stack_changes: "<file><TAB><changed line>" for each added or removed line of a diff on stdin
stack_changes() {
  awk '/^\+\+\+ b\// {f = substr($0, 7); next} /^(\+\+\+|---) / {next}
    /^[+-]/ && f != "" && length($0) > 1 {print f "\t" $0}'
}

# stack_diff_is_own <first> <second>: the second PR adds NOTES.md and repeats none of the first PR's
# changed lines in the same file (an agent may add a test or a README pointer of its own; that is
# still its own change)
stack_diff_is_own() {
  local first second dup
  first=$(gh pr diff "$(e2e_pr_url "$1")" -R "$E2E_REPO" | stack_changes) || return 1
  second=$(gh pr diff "$(e2e_pr_url "$2")" -R "$E2E_REPO" | stack_changes) || return 1
  grep -q $'^NOTES.md\t+' <<<"$second" || return 1
  dup=$(grep -xF -f <(printf '%s\n' "$first") <<<"$second" || true)
  [ -z "$dup" ] || {
    e2e_log "the second PR repeats changes of the first: $dup"
    return 1
  }
}

# shellcheck shell=bash
# t1: a bug issue, tier T1 (see docs/development.md, "End-to-end runs")

E2E_TIMEOUT=5400

scenario_main() {
  local url
  url=$(gh issue create -R "$E2E_REPO" --title "count_vowels ignores uppercase vowels" \
    --body "count_vowels(\"AEIOU\") returns 0; expected 5. (e2e $E2E_BASE)") || return 1
  E2E_ISSUE="${url##*/}"
  e2e_new_run "$E2E_PREFIX-$E2E_ISSUE" --tier T1 --yes || return 1
  e2e_wait "$E2E_ID" '.state == "done"' "$E2E_TIMEOUT" || return 1
  e2e_assert "triage recommendation is in the ledger" e2e_triage_recorded "$E2E_ID" || return 1
  e2e_assert "ledger has a review event" e2e_ledger_has "$E2E_ID" 'any(.events[]; .type == "review")' || return 1
  e2e_assert "notes.md, if the run wrote one, has matching ledger note events" t1_notes_match "$E2E_ID" || return 1
  e2e_assert "no classifier denial in the run logs" t1_no_denial "$E2E_ID" || return 1
  e2e_assert "PR is open against the base" e2e_pr_open_against_base "$E2E_ID" || return 1
  e2e_assert "first test commit fails alone, head passes" t1_tests_first || return 1
  e2e_assert "PR checks are green" e2e_pr_checks_green "$E2E_ID" 20 || return 1
}

# t1_notes_match <id>: a clean T1 run needs no follow-up note; if RUN/notes.md exists in the
# worktree that holds the run's ledger, the ledger must have at least as many note events as
# numbered lines. No ledger found is a failure.
t1_notes_match() {
  local dir notes lines
  dir=$(e2e_run_dir "$1") || {
    e2e_log "no ledger of $1 in its worktree"
    return 1
  }
  notes="$dir/notes.md"
  [ -f "$notes" ] || return 0
  lines=$(grep -c '^[0-9][0-9]*\. ' "$notes" || true)
  [ "$lines" -eq 0 ] || e2e_ledger_has "$1" "[.events[] | select(.type == \"note\")] | length >= $lines"
}

# Auto mode classifier denials. The first two texts are Claude Code's own (CLI 2.1.291): the
# tool result of a denied call starts with "Permission for this action was denied by the Claude
# Code auto mode classifier. Reason: ", and a call the classifier could not judge gets "Auto mode
# could not evaluate this action and is blocking it for safety". The rest are the earlier guesses,
# kept in case the wording changes.
T1_DENIAL_RE='denied by the Claude Code auto mode classifier|Auto mode could not evaluate this action and is blocking it|denied by (the )?(auto mode )?classifier|classifier (denied|blocked)'

# t1_no_denial <id>: no session log of the run mentions an auto mode classifier denial
t1_no_denial() {
  ! grep -rqiE "$T1_DENIAL_RE" "${NS_CONFIG_DIR:-$HOME/.config/ns}/logs/$1" 2>/dev/null
}

# t1_pytest <dir>: set up the stack's virtualenv in <dir> and run pytest
t1_pytest() {
  (
    cd "$1" || exit 1
    python3 -m venv .venv
    .venv/bin/python -m pip install --quiet --upgrade pip
    .venv/bin/python -m pip install --quiet -e '.[test]'
    .venv/bin/python -m pytest -q
  ) >"$E2E_ROOT/t1-pytest.log" 2>&1
}

# the first commit touching tests/ on the fix branch must make pytest fail when
# checked out alone; the head must pass
t1_tests_first() {
  local clone head first wt rc
  clone=$(e2e_verify_clone)
  head=$(e2e_pr_head_branch "$E2E_ID")
  first=$(git -C "$clone" log --no-merges --reverse --format=%H "origin/$E2E_BASE..origin/$head" -- tests/ | head -1)
  [ -n "$first" ] || {
    e2e_log "no commit touches tests/"
    return 1
  }
  wt="$E2E_ROOT/verify-first"
  git -C "$clone" worktree add -q --detach "$wt" "$first"
  rc=0
  if t1_pytest "$wt"; then
    e2e_log "pytest passes on the first test commit $first: the test does not expose the bug"
    rc=1
  fi
  git -C "$clone" worktree remove --force "$wt"
  [ "$rc" -eq 0 ] || return 1
  wt="$E2E_ROOT/verify-head"
  git -C "$clone" worktree add -q --detach "$wt" "origin/$head"
  t1_pytest "$wt" || rc=1
  git -C "$clone" worktree remove --force "$wt"
  return "$rc"
}

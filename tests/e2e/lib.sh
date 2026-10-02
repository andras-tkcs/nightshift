# shellcheck shell=bash
# End-to-end harness library (docs/build-a-plan.md, D20). Sourced by tests/e2e/run.sh,
# which defines the readonly constant E2E_REPO before sourcing this file.
# The only GitHub repository any function here touches is "$E2E_REPO".

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_REPO_ROOT="$(cd "$E2E_DIR/../.." && pwd)"
E2E_FIXTURE="$E2E_REPO_ROOT/tests/fixtures/sandbox-base"
E2E_RESULTS="$E2E_DIR/results.md"
E2E_PROJECT="${E2E_REPO#*/}"
E2E_PREFIX=sbx

E2E_BASE=""
E2E_ROOT=""
E2E_ID=""
E2E_ISSUE=""
E2E_KEEP=0
E2E_FAILURES=0

e2e_log() { printf 'e2e: %s\n' "$*" >&2; }

e2e_root_for() { printf '%s/.cache/ns-e2e/%s\n' "$HOME" "${1//\//-}"; }

# e2e_env_setup <base branch>: isolated environment, the real ~/.claude login is used
e2e_env_setup() {
  E2E_BASE="$1"
  E2E_ROOT="$(e2e_root_for "$E2E_BASE")"
  mkdir -p "$E2E_ROOT/config" "$E2E_ROOT/desk" "$E2E_ROOT/coding"
  export NS_HOME="$E2E_REPO_ROOT"
  export NS_CONFIG_DIR="$E2E_ROOT/config"
  export NS_DESK_DIR="$E2E_ROOT/desk"
  export NS_CODING_DIR="$E2E_ROOT/coding"
  export NS_PLUGIN_DIRS="$E2E_REPO_ROOT/plugins/ns:$E2E_REPO_ROOT/plugins/ns-python"
  export NS_WORKER_MODE=auto
  export PATH="$E2E_REPO_ROOT/bin:$PATH"
  unset NS_NTFY_TOPIC
}

# e2e_gh_git <git args...>: git with the gh credential helper, for pushes and clones
e2e_gh_git() {
  git -c credential.helper= -c credential.helper='!gh auth git-credential' "$@"
}

# e2e_next_base: print e2e/<yyyymmdd>-<k>
e2e_next_base() {
  local day n
  day=$(date +%Y%m%d)
  n=$(gh api "repos/$E2E_REPO/git/matching-refs/heads/e2e/$day-" --jq 'length')
  printf 'e2e/%s-%s\n' "$day" "$((n + 1))"
}

# e2e_render_profile <base branch> <out file>
e2e_render_profile() {
  mkdir -p "$(dirname "$2")"
  sed "s|@BASE_BRANCH@|$1|g" "$E2E_FIXTURE/project-profile.yaml.tmpl" >"$2"
}

# e2e_create_base <base branch>: orphan branch from the fixture, pushed to $E2E_REPO
e2e_create_base() {
  local branch="$1" tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/e2e-base.XXXXXX")"
  git init -q "$tmp"
  git -C "$tmp" checkout -q --orphan "$branch"
  (cd "$E2E_FIXTURE" && tar cf - --exclude=project-profile.yaml.tmpl .) | tar xf - -C "$tmp"
  e2e_render_profile "$branch" "$tmp/.claude/project-profile.yaml"
  git -C "$tmp" add -A
  git -C "$tmp" commit -q -m "e2e base $branch"
  git -C "$tmp" remote add origin "https://github.com/$E2E_REPO.git"
  e2e_gh_git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  rm -rf "$tmp"
}

e2e_project_add() {
  ns project add "$E2E_REPO" --prefix "$E2E_PREFIX" --sandbox --branch "$E2E_BASE"
}

# e2e_status_json <id>
e2e_status_json() { ns status "$1" --json; }

# e2e_wait <id> <jq predicate on the ledger> <timeout s>
e2e_wait() {
  local id="$1" pred="$2" timeout="$3" start now json state gate
  start=$(date +%s)
  while :; do
    json=$(e2e_status_json "$id" 2>/dev/null || true)
    if [ -n "$json" ]; then
      if jq -e "$pred" <<<"$json" >/dev/null 2>&1; then
        return 0
      fi
      state=$(jq -r '.state' <<<"$json")
      gate=$(jq -r '.gate // ""' <<<"$json")
      if [ "$state" = failed ]; then
        e2e_log "run $id failed while waiting for: $pred"
        return 1
      fi
      if [ "$gate" = "1.5" ]; then
        e2e_log "run $id escalated at gate 1.5 while waiting for: $pred"
        e2e_print_escalation "$id"
        return 1
      fi
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout" ]; then
      e2e_log "timeout after ${timeout}s waiting for: $pred"
      return 1
    fi
    sleep 30
  done
}

e2e_desk_dir() { printf '%s/%s/runs/%s\n' "$NS_DESK_DIR" "$E2E_PROJECT" "$1"; }

e2e_print_escalation() {
  local f
  f="$(e2e_desk_dir "$1")/escalation.md"
  if [ -f "$f" ]; then cat "$f" >&2; else e2e_log "no escalation.md on the desk for $1"; fi
}

# e2e_assert <description> <command...>: records a failure, returns 1
e2e_assert() {
  local desc="$1"
  shift
  if "$@"; then
    e2e_log "ok: $desc"
    return 0
  fi
  e2e_log "FAILED: $desc"
  E2E_FAILURES=$((E2E_FAILURES + 1))
  return 1
}

# jq predicate on the ledger of <id>
e2e_ledger_has() { e2e_status_json "$1" | jq -e "$2" >/dev/null; }

e2e_ledger_get() { e2e_status_json "$1" | jq -r "$2"; }

e2e_pr_url() { e2e_ledger_get "$1" '.pr // ""'; }

e2e_pr_json() { gh pr view "$(e2e_pr_url "$1")" -R "$E2E_REPO" --json "$2"; }

# e2e_pr_open_against_base <id>
e2e_pr_open_against_base() {
  local url j
  url=$(e2e_pr_url "$1")
  [ -n "$url" ] || return 1
  j=$(e2e_pr_json "$1" state,baseRefName)
  jq -e --arg b "$E2E_BASE" '.state == "OPEN" and .baseRefName == $b' <<<"$j" >/dev/null
}

# e2e_pr_checks_green <id> [timeout minutes]
e2e_pr_checks_green() {
  local url
  url=$(e2e_pr_url "$1")
  [ -n "$url" ] || return 1
  timeout "$((${2:-20} * 60))" gh pr checks "$url" -R "$E2E_REPO" --watch >/dev/null
}

e2e_budget_within_limit() {
  e2e_ledger_has "$1" '.budget.limit != null and .budget.used <= .budget.limit'
}

e2e_triage_recorded() { e2e_ledger_has "$1" '.tier_recommended != null'; }

# e2e_pr_head_branch <id>
e2e_pr_head_branch() { e2e_pr_json "$1" headRefName | jq -r '.headRefName'; }

# e2e_pr_file <id> <path>: contents of a file on the PR branch
e2e_pr_file() {
  local br
  br=$(e2e_pr_head_branch "$1")
  gh api "repos/$E2E_REPO/contents/$2?ref=$br" --jq .content | base64 -d
}

# e2e_verify_clone: print the path of a clone of the repo for history checks
e2e_verify_clone() {
  local d="$E2E_ROOT/verify"
  if [ ! -d "$d/.git" ]; then
    e2e_gh_git clone -q "https://github.com/$E2E_REPO.git" "$d"
  fi
  e2e_gh_git -C "$d" fetch -q origin
  printf '%s\n' "$d"
}

# e2e_each_trailer_once <id>: every phase's Plan-Phase trailer appears exactly once on the PR branch
e2e_each_trailer_once() {
  local clone head p n ok=0
  clone=$(e2e_verify_clone)
  head=$(e2e_pr_head_branch "$1")
  while IFS= read -r p; do
    n=$(git -C "$clone" log "origin/$head" --format=%B | grep -c "^Plan-Phase: $p\$" || true)
    if [ "$n" -ne 1 ]; then
      e2e_log "trailer Plan-Phase: $p appears $n times"
      ok=1
    fi
  done < <(e2e_ledger_get "$1" '.phases[].id')
  return "$ok"
}

# e2e_approve <id>: gate 1, with plan.md and acceptance.md on the desk
e2e_approve() {
  local id="$1" d
  d=$(e2e_desk_dir "$id")
  e2e_assert "plan.md is on the desk" test -f "$d/plan.md" || return 1
  e2e_assert "acceptance.md is on the desk" test -f "$d/acceptance.md" || return 1
  ns approve "$id" --yes
}

# e2e_new_run <ns new args...>: start a run, sets E2E_ID
e2e_new_run() {
  local out
  out=$(ns new "$@")
  printf '%s\n' "$out" >&2
  E2E_ID=$(sed -n 's/^started \([^ ]*\) in tmux session.*/\1/p' <<<"$out" | head -1)
  [ -n "$E2E_ID" ] || {
    e2e_log "could not read the run id from ns new output"
    return 1
  }
}

# e2e_pane_pid <id>: pid of the tmux pane (the conductor's claude, D9)
e2e_pane_pid() { tmux list-panes -t "=$1" -F '#{pane_pid}' | head -1; }

e2e_session_gone() { ! tmux has-session -t "=$1" 2>/dev/null; }

# e2e_gh_delete_branch <branch>: only branches this harness could have created
e2e_gh_delete_branch() {
  case "$1" in
    e2e/* | plan/sbx-* | fix/sbx-* | feature/*) ;;
    *)
      e2e_log "refusing to delete branch $1"
      return 0
      ;;
  esac
  gh api -X DELETE "repos/$E2E_REPO/git/refs/heads/$1" >/dev/null 2>&1 || true
}

# e2e_gh_delete_attempt_branch <base> <branch>: delete <branch> only when it grew from <base>,
# so a branch of an older attempt that a ledger happens to name (same run id) survives
e2e_gh_delete_attempt_branch() {
  local status
  status=$(gh api "repos/$E2E_REPO/compare/$1...$2" --jq .status 2>/dev/null) || status=""
  case "$status" in
    ahead | identical) e2e_gh_delete_branch "$2" ;;
    *) e2e_log "keeping branch $2: it does not grow from $1" ;;
  esac
}

# e2e_branches_of_ledgers <dir>: branches named in every ledger below <dir>
e2e_branches_of_ledgers() {
  local f
  while IFS= read -r f; do
    "$E2E_REPO_ROOT/bin/ns-ledger" get "$f" '[.branch, .feature_branch, (.phases[]?.branch)] | .[] | select(. != null)' 2>/dev/null || true
  done < <(find "$1" -name ledger.yaml -path '*/.nightshift/runs/*' 2>/dev/null) | sort -u
}

# e2e_close_prs_on_base <base>
e2e_close_prs_on_base() {
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    gh pr close "$n" -R "$E2E_REPO" --delete-branch >/dev/null 2>&1 || true
  done < <(gh pr list -R "$E2E_REPO" --base "$1" --state open --json number --jq '.[].number')
}

# e2e_close_issues_naming <base>
e2e_close_issues_naming() {
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    gh issue close "$n" -R "$E2E_REPO" >/dev/null 2>&1 || true
  done < <(gh issue list -R "$E2E_REPO" --state open --search "\"$1\" in:body" --json number --jq '.[].number')
}

# e2e_stop_run <id>: kill the run's tmux session and workers
e2e_stop_run() {
  [ -n "$1" ] || return 0
  tmux kill-session -t "=$1" 2>/dev/null || true
  ns-conductor stop "$1" >/dev/null 2>&1 || true
}

# e2e_remote_cleanup <base> <root>: close what an attempt left on GitHub, delete its branches
e2e_remote_cleanup() {
  local base="$1" root="$2" b
  e2e_close_prs_on_base "$base"
  e2e_close_issues_naming "$base"
  while IFS= read -r b; do
    [ -n "$b" ] && e2e_gh_delete_attempt_branch "$base" "$b"
  done < <(e2e_branches_of_ledgers "$root")
  e2e_gh_delete_branch "$base"
}

# e2e_record <scenario> <PASS|FAIL> <pr or -> <run id or -> <minutes>
e2e_record() {
  printf '| %s | %s | %s | %s | %s | %s |\n' "$(date +%Y-%m-%d)" "$1" "$2" "$3" "$4" "$5" >>"$E2E_RESULTS"
}

# e2e_finish <scenario> <rc of scenario_main> <start seconds>: result line, cleanup; prints, returns exit code
e2e_finish() {
  local scenario="$1" rc="$2" start="$3" result pr minutes
  minutes=$(((SECONDS - start + 59) / 60))
  pr=-
  if [ -n "$E2E_ID" ]; then
    pr=$(e2e_pr_url "$E2E_ID" 2>/dev/null || true)
    [ -n "$pr" ] || pr=-
  fi
  result=PASS
  [ "$rc" -eq 0 ] || result=FAIL
  e2e_record "$scenario" "$result" "$pr" "${E2E_ID:--}" "$minutes"
  e2e_stop_run "$E2E_ID"
  if [ "$result" = PASS ]; then
    if [ "$E2E_KEEP" -eq 0 ]; then
      e2e_close_prs_on_base "$E2E_BASE"
      [ -z "$E2E_ISSUE" ] || gh issue close "$E2E_ISSUE" -R "$E2E_REPO" >/dev/null 2>&1 || true
      e2e_remote_cleanup "$E2E_BASE" "$E2E_ROOT"
    fi
    rm -rf "$E2E_ROOT"
    e2e_log "$scenario PASS ($minutes min) $pr"
    return 0
  fi
  e2e_log "$scenario FAIL ($minutes min); kept $E2E_ROOT; base branch $E2E_BASE"
  return 1
}

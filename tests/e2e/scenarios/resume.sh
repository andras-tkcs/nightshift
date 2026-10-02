# shellcheck shell=bash
# resume: kill the conductor mid-run and resume it (see docs/development.md, "End-to-end runs")

E2E_TIMEOUT=10800

scenario_main() {
  local pid i
  e2e_new_run "$E2E_PREFIX" "Add titlecase(text) to sandbox_pkg/text.py: lowercase, spaces and punctuation become single hyphens, no leading or trailing hyphen. Add tests and a README section." --tier T2 --yes || return 1
  e2e_wait "$E2E_ID" '.gate == "1"' "$E2E_TIMEOUT" || return 1
  e2e_approve "$E2E_ID" || return 1
  e2e_wait "$E2E_ID" 'any(.phases[]; .state == "running")' "$E2E_TIMEOUT" || return 1
  # only the pid of this run's own conductor, never a pattern kill (other sessions run here)
  pid=$(e2e_conductor_pid "$E2E_ID") || return 1
  e2e_log "kill -9 $pid (the conductor)"
  kill -9 "$pid"
  for i in $(seq 1 60); do
    e2e_session_gone "$E2E_ID" && break
    [ "$i" -lt 60 ] || {
      e2e_log "tmux session $E2E_ID is still there after the kill"
      return 1
    }
    sleep 2
  done
  ns resume "$E2E_ID" || return 1
  e2e_wait "$E2E_ID" '.state == "done"' "$E2E_TIMEOUT" || return 1
  e2e_assert "each Plan-Phase trailer appears exactly once" e2e_each_trailer_once "$E2E_ID" || return 1
  e2e_assert "no duplicate commit subjects" resume_no_duplicates || return 1
  e2e_assert "PR is open against the base" e2e_pr_open_against_base "$E2E_ID" || return 1
}

resume_no_duplicates() {
  local clone head dups
  clone=$(e2e_verify_clone)
  head=$(e2e_pr_head_branch "$E2E_ID")
  dups=$(git -C "$clone" log --no-merges --format=%s "origin/$E2E_BASE..origin/$head" | sort | uniq -d)
  [ -z "$dups" ] || {
    printf '%s\n' "$dups" >&2
    return 1
  }
}

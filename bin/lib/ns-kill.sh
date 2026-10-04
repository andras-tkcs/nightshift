# shellcheck shell=bash
# summary: kill a run now: session, conductor and workers

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/pool.sh"

ns_kill_help() {
  printf 'usage: ns kill <id>\n\n'
  printf 'Stop a run at once: end its tmux session, kill the conductor and every worker\n'
  printf 'process group, reset running phases to pending and mark the run stopped. The\n'
  printf 'worktree and branches are kept; ns resume restarts it. Owner only.\n'
}

# ns_kill_group <pid>: TERM, then KILL, the process group led by <pid>
ns_kill_group() {
  local pid="$1" pgid i
  [[ $pid =~ ^[0-9]+$ ]] || return 0
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || pgid=""
  [ "$pgid" = "$pid" ] || return 0
  [ "$pgid" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 20 ] && ns_pool_pid_alive "$pid"; do
    sleep 0.25
    i=$((i + 1))
  done
  kill -KILL -- "-$pid" 2>/dev/null || true
}

# ns_kill_teardown <id> <ledger> <note> <event> [kill-session]
# Kills workers (and the session when asked), resets running phases, marks the run stopped.
ns_kill_teardown() {
  local id="$1" ledger="$2" note="$3" event="$4" session="${5:-}" pane="" r phase f
  if [ -n "$session" ] && ns_tmux_has "$id"; then
    pane=$(ns_tmux_pane_pid "$id" 2>/dev/null) || pane=""
    ns_tmux_kill "$id" || true
    ns_kill_group "$pane"
  fi
  while read -r r phase; do
    [ -n "$phase" ] || continue
    f="$(ns_pool_dir)/$r--$phase.pid"
    ns_kill_group "$(ns_pool_field "$f" pid)"
    rm -f "$f" "$(ns_pool_dir)/$r--$phase.exit"
  done < <(ns_pool_live "$id")
  "$NS_HOME/bin/ns-ledger" set "$ledger" '.phases |= map(if .state == "running" then .state = "pending" else . end) | .stop_requested = null'
  "$NS_HOME/bin/ns-ledger" state "$ledger" stopped --note "$note"
  "$NS_HOME/bin/ns-ledger" event "$ledger" "$event" "$note"
  "$NS_HOME/bin/ns-ledger" checkpoint "$ledger"
}

ns_kill_main() {
  local u="ns kill <id>"
  [ $# -eq 1 ] && [[ $1 != -* ]] || ns_usage "$u"
  local id="$1" ledger state
  ns_run_get "$id" >/dev/null || ns_die "unknown run $id"
  ledger=$(ns_run_ledger "$id")
  [ -f "$ledger" ] || ns_die "no ledger for $id: worktree missing, try ns resume $id"
  state=$("$NS_HOME/bin/ns-ledger" get "$ledger" .state)
  case "$state" in
    stopped | done | failed)
      if ! ns_tmux_has "$id" && [ -z "$(ns_pool_live "$id")" ]; then
        printf '%s is already %s\n' "$id" "$state"
        return 0
      fi
      ;;
  esac
  ns_kill_teardown "$id" "$ledger" "killed by owner" killed session
  "$NS_HOME/bin/ns-notify" "ns: $id killed by owner" || ns_warn "notification failed"
  printf 'killed %s; ns resume %s restarts it\n' "$id" "$id"
}

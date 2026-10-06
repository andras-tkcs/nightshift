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

# ns_kill_group_live <pgid>: succeeds while a process of the group is alive and not a zombie
ns_kill_group_live() {
  local p
  for p in $(pgrep -g "$1" 2>/dev/null); do
    ns_pool_pid_alive "$p" && return 0
  done
  return 1
}

# ns_kill_group <pid>: TERM, then KILL, the process group led by <pid>, then wait (about 2 s at
# most) until no live process is left in it, so that a ledger write after this cannot
# interleave with a conductor that checkpoints on its way out
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
  i=0
  while [ "$i" -lt 20 ] && ns_kill_group_live "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! ns_kill_group_live "$pid" || ns_warn "process group $pid is still alive after SIGKILL"
}

# ns_kill_teardown <id> <ledger> <note> [--session] [--keep-state]
# Kills workers (and the session with --session), resets running phases, marks the run stopped.
# With --keep-state (done/failed runs) only the processes are killed; the ledger is untouched.
# The ledger is written only after every killed process group is gone (ns_kill_group waits).
ns_kill_teardown() {
  local u="ns_kill_teardown <id> <ledger> <note> [--session] [--keep-state]"
  [ $# -ge 3 ] || ns_usage "$u"
  local id="$1" ledger="$2" note="$3" session="" keep="" pane="" r phase f
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session=1 ;;
      --keep-state) keep=1 ;;
      *) ns_usage "$u" ;;
    esac
    shift
  done
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
  [ -z "$keep" ] || return 0
  "$NS_HOME/bin/ns-ledger" set "$ledger" '.phases |= map(if .state == "running" then .state = "pending" else . end) | .stop_requested = null'
  "$NS_HOME/bin/ns-ledger" state "$ledger" stopped --note "$note"
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
      if [ "$state" != stopped ]; then
        ns_kill_teardown "$id" "$ledger" "killed by owner" --session --keep-state
        printf 'killed leftover processes of %s (state stays %s)\n' "$id" "$state"
        return 0
      fi
      ;;
  esac
  ns_kill_teardown "$id" "$ledger" "killed by owner" --session
  # best effort: the report of a stopped run, committed with the ledger
  if "$NS_HOME/bin/ns" report "$id" >/dev/null 2>&1; then
    "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push || ns_warn "could not commit the run report"
  else
    ns_warn "could not write the run report for $id"
  fi
  "$NS_HOME/bin/ns-notify" "ns: $id killed by owner" || ns_warn "notification failed"
  printf 'killed %s; ns resume %s restarts it\n' "$id" "$id"
  "$NS_HOME/bin/ns" dequeue >/dev/null || ns_warn "ns dequeue failed"
}

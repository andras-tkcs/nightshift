# shellcheck shell=bash
# summary: start queued runs while a slot is free

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/queue.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/ns-resume.sh"

ns_dequeue_help() {
  printf 'usage: ns dequeue\n\n'
  printf 'Start queued runs, oldest first, while fewer than max_runs conductors are live.\n'
  printf 'Called when a conductor ends; safe to run by hand and concurrently.\n'
}

ns_dequeue_main() {
  [ $# -eq 0 ] || ns_usage "ns dequeue"
  local id rc started=0 left=0 ledger
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ "$(ns_queue_live_count)" -ge "$(ns_queue_max)" ]; then
      left=$((left + 1))
      continue
    fi
    rc=0
    (ns_resume_one "$id") || rc=$?
    if [ "$rc" -eq 0 ] && ns_tmux_has "$id"; then
      ledger=$(ns_run_ledger "$id")
      "$NS_HOME/bin/ns-ledger" event "$ledger" dequeued "started from the queue"
      "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push
      "$NS_HOME/bin/ns-notify" "ns: $id left the queue and started" || ns_warn "notification failed"
      started=$((started + 1))
    else
      left=$((left + 1))
    fi
  done < <(ns_queue_list)
  printf 'ns dequeue: %s started, %s still queued\n' "$started" "$left"
}

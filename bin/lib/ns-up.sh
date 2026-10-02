# shellcheck shell=bash
# summary: start Nightshift after a reboot

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

ns_up_help() {
  printf 'usage: ns up\n\n'
  printf 'After a reboot: run ns doctor, start the Remote Control session (tmux "rc") and\n'
  printf 'list parked runs. Exits with the code of ns doctor.\n'
}

ns_up_main() {
  [ $# -eq 0 ] || ns_usage "ns up"
  local rc=0 out dir
  out=$("$NS_HOME/bin/ns" doctor 2>&1) || rc=$?
  if [ "$rc" -eq 2 ] && [[ $out == *"unknown command"* ]]; then
    printf 'doctor: not available yet\n'
    rc=0
  elif [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi

  dir=$(ns_config_get remote_control_dir "")
  if [ -z "$dir" ]; then
    dir=$(ns_projects_json | jq -r '.[0].path // empty')
  fi
  if [ -z "$dir" ]; then
    printf 'Remote Control: no project registered yet\n'
  elif ns_tmux_has rc; then
    printf 'Remote Control: already running\n'
  else
    dir=$(ns_expand_path "$dir")
    ns_tmux_start rc "$dir" "claude remote-control --spawn worktree --name \"\$(hostname -s)\""
    printf 'Remote Control: started in %s\n' "$dir"
  fi

  local id ledger parked=()
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ledger=$(ns_run_ledger "$id")
    [ -f "$ledger" ] || continue
    if [ "$("$NS_HOME/bin/ns-ledger" get "$ledger" .state 2>/dev/null)" = parked ]; then
      parked+=("$id")
    fi
  done < <(ns_runs_json | jq -r '.[] | select(.archived | not) | .id')
  if [ "${#parked[@]}" -gt 0 ]; then
    printf 'parked: %s\n' "${parked[*]}"
    printf 'resume them with: ns resume --all\n'
  fi
  return "$rc"
}

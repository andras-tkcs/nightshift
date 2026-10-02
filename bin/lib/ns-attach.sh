# shellcheck shell=bash
# summary: attach to a run's session

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

ns_attach_help() {
  printf 'usage: ns attach <id>\n\n'
  printf "Attach to the run's tmux session (detach with Ctrl-b d).\n"
}

ns_attach_main() {
  local u="ns attach <id>"
  [ $# -eq 1 ] && [[ $1 != -* ]] || ns_usage "$u"
  local id="$1"
  ns_tmux_has "$id" || ns_die "no tmux session $id: start it with ns resume $id"
  exec tmux attach-session -t "=$id"
}

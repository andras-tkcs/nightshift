# shellcheck shell=bash
# summary: show a run's session log, readable

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"

ns_log_help() {
  printf 'usage: ns log <id> [-f] [--phase <p>] [--raw]\n\n'
  printf "Show the run's session logs (logs/<id>/*.jsonl) as readable text, wrapped to\n"
  printf 'the terminal width. --phase <p> shows only logs/<id>/<p>.jsonl, --raw prints the\n'
  printf 'JSONL unchanged, -f follows new output.\n'
}

ns_log_main() {
  local u="ns log <id> [-f] [--phase <p>] [--raw]"
  local id="" phase="" raw=0 follow=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -f) follow=1 ;;
      --raw) raw=1 ;;
      --phase)
        [ $# -ge 2 ] || ns_usage "$u"
        phase=$2
        shift
        ;;
      -*) ns_usage "$u" ;;
      *)
        [ -z "$id" ] || ns_usage "$u"
        id=$1
        ;;
    esac
    shift
  done
  [ -n "$id" ] || ns_die "missing run id (usage: $u)"
  local dir files=()
  dir="$(ns_config_dir)/logs/$id"
  [ -d "$dir" ] || ns_die "no logs for $id: $dir does not exist"
  if [ -n "$phase" ]; then
    [ -f "$dir/$phase.jsonl" ] || ns_die "no log for phase $phase of $id: $dir/$phase.jsonl"
    files=("$dir/$phase.jsonl")
  else
    local f
    for f in "$dir"/*.jsonl; do
      [ -f "$f" ] && files+=("$f")
    done
    [ ${#files[@]} -gt 0 ] || ns_die "no .jsonl logs for $id in $dir"
  fi
  local src=(cat)
  [ "$follow" -eq 1 ] && src=(tail -n +1 -f)
  if [ "$raw" -eq 1 ]; then
    exec "${src[@]}" "${files[@]}"
  fi
  local cols=${COLUMNS:-}
  [ -n "$cols" ] || cols=$(tput cols 2>/dev/null || echo 80)
  [ -t 1 ] || cols=${COLUMNS:-80}
  # not exec: with tail -f the pipe ends when the reader or tail is interrupted
  "${src[@]}" "${files[@]}" | COLUMNS=$cols python3 "$NS_HOME/bin/lib/stream-view.py"
}

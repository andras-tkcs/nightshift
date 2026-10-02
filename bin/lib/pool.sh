# shellcheck shell=bash
# Worker pool: pid files in $NS_CONFIG_DIR/workers. Source this file; it defines functions only.
# Needs common.sh and config.sh.

ns_pool_dir() { printf '%s/workers\n' "$(ns_config_dir)"; }

# ns_pool_pid_alive <pid>: running and not a zombie
ns_pool_pid_alive() {
  local st
  kill -0 "$1" 2>/dev/null || return 1
  st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ') || st=""
  [ -n "$st" ] && [[ $st != Z* ]]
}

# ns_pool_field <pid file> <key>
ns_pool_field() {
  sed -n "s/^$2=//p" "$1" | head -n1
}

# shellcheck disable=SC2120
# ns_pool_live [<run>]: prints "<run> <phase>" for each live worker
ns_pool_live() {
  local dir f base pid
  dir="$(ns_pool_dir)"
  for f in "$dir"/*.pid; do
    [ -f "$f" ] || continue
    base=${f##*/}
    base=${base%.pid}
    [ -z "${1:-}" ] || [[ $base == "$1"--* ]] || continue
    [ ! -e "$dir/$base.exit" ] || continue
    pid=$(ns_pool_field "$f" pid)
    [[ $pid =~ ^[0-9]+$ ]] || continue
    ns_pool_pid_alive "$pid" || continue
    printf '%s %s\n' "${base%%--*}" "${base#*--}"
  done
}

ns_pool_count() {
  ns_pool_live '' | wc -l | tr -d ' '
}

ns_pool_max() {
  ns_config_get max_workers 2
}

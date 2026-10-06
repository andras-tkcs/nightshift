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

# ns_pool_locked <cmd...>: run the command holding the exclusive pool lock (workers/.lock), so
# the count, the spawn and the pid-file wait of one start are atomic across runs (R-CON-2).
# The lock is an flock, released when the subshell exits on any path; a lock file left behind
# never blocks. >> never truncates the file a symlinked .lock points to. Returns 12 when the
# lock stays busy for NS_POOL_LOCK_WAIT seconds (default 60); any other flock failure dies.
# A process started under the lock must close fd 9 (9>&-), or it holds the lock for its life.
ns_pool_locked() {
  local dir wait="${NS_POOL_LOCK_WAIT:-60}"
  [[ $wait =~ ^[0-9]+$ ]] || ns_die "NS_POOL_LOCK_WAIT must be a number of seconds, got '$wait'"
  dir="$(ns_pool_dir)"
  mkdir -p "$dir" || ns_die "cannot create $dir"
  (
    local rc=0
    flock -w "$wait" 9 || rc=$?
    # flock exits 1 on a timeout (its -E default); anything else is an error, not a busy lock
    [ "$rc" -ne 1 ] || exit 12
    [ "$rc" -eq 0 ] || ns_die "cannot take the pool lock $dir/.lock (flock exit $rc)"
    "$@"
  ) 9>>"$dir/.lock"
}

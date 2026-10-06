#!/usr/bin/env bash
# pool-watch.sh: watch the worker pool of one Nightshift home and report the most live workers
# seen (R-CON-2). Read-only: it reads pid and exit files and /proc, and changes nothing.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: tests/e2e/pool-watch.sh [--config-dir <dir>] [--interval <s>] [--once]

Every <interval> seconds (default 5) prints one line:
  <UTC time> live=<n> procs=<m> max=<k> [<run>--<phase> ...]
live   workers in <dir>/workers with a pid file, no exit file and a running process
       (the count ns-conductor start uses)
procs  ns-worker processes whose environment has NS_CONFIG_DIR=<dir> (a cross-check
       that does not trust the pid files)
max    the highest of live and procs seen since the start
<dir> defaults to $NS_CONFIG_DIR, else ~/.config/ns. --once prints one line and exits.
On exit (Ctrl-C, SIGTERM) it prints "max live workers seen: <k>".
EOF
}

dir="${NS_CONFIG_DIR:-$HOME/.config/ns}"
interval=5
once=0
while [ $# -gt 0 ]; do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --config-dir)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      dir="$2"
      shift 2
      ;;
    --interval)
      [ $# -ge 2 ] && [[ $2 =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
      interval="$2"
      shift 2
      ;;
    --once)
      once=1
      shift
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done
dir="${dir%/}"

# alive <pid>: running and not a zombie
alive() {
  local st
  kill -0 "$1" 2>/dev/null || return 1
  st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ') || st=""
  [ -n "$st" ] && [[ $st != Z* ]]
}

# live_workers: one "<run>--<phase>" line per live worker of the pool
live_workers() {
  local f base pid
  for f in "$dir"/workers/*.pid; do
    [ -f "$f" ] || continue
    base=${f##*/}
    base=${base%.pid}
    [ ! -e "$dir/workers/$base.exit" ] || continue
    pid=$(sed -n 's/^pid=//p' "$f" | head -n1)
    [[ $pid =~ ^[0-9]+$ ]] || continue
    alive "$pid" || continue
    printf '%s\n' "$base"
  done
}

# worker_procs: number of ns-worker processes started for this home
worker_procs() {
  local p n=0
  for p in /proc/[0-9]*; do
    [ -r "$p/environ" ] || continue
    tr '\0' '\n' <"$p/cmdline" 2>/dev/null | grep -qxF ns-worker || continue
    tr '\0' '\n' <"$p/environ" 2>/dev/null | grep -qxF "NS_CONFIG_DIR=$dir" || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

max=0
trap 'printf "max live workers seen: %s\n" "$max"; exit 0' INT TERM
while :; do
  names=$(live_workers)
  live=0
  [ -z "$names" ] || live=$(wc -l <<<"$names" | tr -d ' ')
  procs=$(worker_procs)
  [ "$live" -le "$max" ] || max=$live
  [ "$procs" -le "$max" ] || max=$procs
  printf '%s live=%s procs=%s max=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$live" "$procs" "$max" "$(tr '\n' ' ' <<<"$names")"
  if [ "$once" -eq 1 ]; then
    printf 'max live workers seen: %s\n' "$max"
    exit 0
  fi
  sleep "$interval" &
  wait $! || true
done

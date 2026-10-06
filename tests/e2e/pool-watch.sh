#!/usr/bin/env bash
# pool-watch.sh: watch the worker pool of one Nightshift home and report the most live workers
# seen (R-CON-2). Read-only: it reads pid and exit files and /proc, and changes nothing.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: tests/e2e/pool-watch.sh [--config-dir <dir>] [--interval <s>] [--once]

Every <interval> seconds (default 5) prints one line:
  <UTC time> live=<n> procs=<m> max_live=<k> max_procs=<j> [<run>--<phase> ...]
live       workers in <dir>/workers with a pid file, no exit file and a running process
           (the count ns-conductor start uses)
procs      ns-worker session leaders (ns-conductor starts each worker with setsid) whose
           environment has NS_CONFIG_DIR=<dir>: a cross-check that does not trust the pid files
max_live, max_procs   the highest of each seen since the start
<dir> defaults to $NS_CONFIG_DIR, else ~/.config/ns. --once prints one line and exits.
On exit (Ctrl-C, SIGTERM) it prints "max live workers seen: <k> (procs: <j>)".
Exits 1 when live workers have no ns-worker process for <dir> (checked twice, 1 s apart):
the cross-check would otherwise stay at 0 without saying so (a wrong --config-dir, say).
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

# session_leader <pid>: the process leads its session (pid == sid). A worker's own forks keep
# its command line until they exec, so they would be counted twice without this.
session_leader() {
  local stat sid
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  # the fields after "(<command>) " are: state ppid pgrp session ...
  read -r _ _ _ sid _ <<<"${stat##*) }"
  [ "$sid" = "$1" ]
}

# worker_procs: number of ns-worker processes started for this home
worker_procs() {
  local p n=0
  for p in /proc/[0-9]*; do
    # 2> first: a process that is gone by now must not print an error
    tr '\0' '\n' 2>/dev/null <"$p/cmdline" | grep -qxF ns-worker || continue
    tr '\0' '\n' 2>/dev/null <"$p/environ" | grep -qxF "NS_CONFIG_DIR=$dir" || continue
    session_leader "${p#/proc/}" || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

max_live=0
max_procs=0
trap 'printf "max live workers seen: %s (procs: %s)\n" "$max_live" "$max_procs"; exit 0' INT TERM
while :; do
  names=$(live_workers)
  live=0
  [ -z "$names" ] || live=$(wc -l <<<"$names" | tr -d ' ')
  procs=$(worker_procs)
  if [ "$live" -gt 0 ] && [ "$procs" -eq 0 ]; then
    sleep 1
    names=$(live_workers)
    live=0
    [ -z "$names" ] || live=$(wc -l <<<"$names" | tr -d ' ')
    procs=$(worker_procs)
  fi
  [ "$live" -le "$max_live" ] || max_live=$live
  [ "$procs" -le "$max_procs" ] || max_procs=$procs
  printf '%s live=%s procs=%s max_live=%s max_procs=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$live" "$procs" "$max_live" "$max_procs" "$(tr '\n' ' ' <<<"$names")"
  if [ "$live" -gt 0 ] && [ "$procs" -eq 0 ]; then
    printf 'pool-watch: %s live pid file(s) but no ns-worker process for NS_CONFIG_DIR=%s; is --config-dir right?\n' "$live" "$dir" >&2
    printf 'max live workers seen: %s (procs: %s)\n' "$max_live" "$max_procs"
    exit 1
  fi
  if [ "$once" -eq 1 ]; then
    printf 'max live workers seen: %s (procs: %s)\n' "$max_live" "$max_procs"
    exit 0
  fi
  sleep "$interval" &
  wait $! || true
done

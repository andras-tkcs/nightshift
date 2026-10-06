# shellcheck shell=bash
# Runs index, branch and worktree naming, tmux helpers. Source this file; it defines functions only.
# Needs common.sh and config.sh.

NS_TMUX_ENV_VARS="NS_HOME NS_CONFIG_DIR NS_DESK_DIR NS_CODING_DIR NS_PLUGIN_DIRS NS_WORKER_MODE NS_CLAUDE NS_NOW NS_NTFY_TOPIC NS_NTFY_URL NS_DESK_URL NS_HEALTHCHECK_URL PATH HOME"

# ns_run_parse_id <id>: validate and print "<prefix> <n>" (n is the number, xK or onboard)
ns_run_parse_id() {
  local re='^([a-z][a-z0-9]{0,9})-([0-9]+|x[0-9]+|onboard)$'
  [[ $1 =~ $re ]] || return 1
  printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

ns_runs_json() {
  local file
  file="$(ns_config_dir)/runs.yaml"
  if [ -f "$file" ]; then
    ns_yaml_json "$file" | jq -c '.runs // []'
  else
    printf '[]\n'
  fi
}

# ns_run_get <id>: JSON object, return 1 if absent
ns_run_get() {
  local out
  out=$(ns_runs_json | jq -ce --arg i "$1" '.[] | select(.id == $i)') || return 1
  printf '%s\n' "$out"
}

# ns_runs_write: JSON array on stdin becomes runs.yaml
ns_runs_write() {
  mkdir -p "$(ns_config_dir)"
  jq -c '{runs: .}' | ns_json_yaml "$(ns_config_dir)/runs.yaml"
}

# ns_run_register <json>: append, no-op if an identical entry exists
ns_run_register() {
  local entry="$1" all
  all=$(ns_runs_json)
  if jq -e --argjson e "$entry" 'any(.[]; . == $e)' <<<"$all" >/dev/null; then
    return 0
  fi
  jq -c --argjson e "$entry" '. + [$e]' <<<"$all" | ns_runs_write
}

# ns_run_set <id> <jq-program>: apply the program to one entry
ns_run_set() {
  local id="$1" prog="$2"
  ns_runs_json | jq -c --arg id "$id" "map(if .id == \$id then ($prog) else . end)" | ns_runs_write
}

# ns_run_next_x <prefix>: 1 + the highest x number for the prefix
ns_run_next_x() {
  ns_runs_json | jq -r --arg p "$1" \
    '[.[] | .id | capture("^" + $p + "-x(?<k>[0-9]+)$") | .k | tonumber] | (max // 0) + 1'
}

# ns_run_ledger <id>
ns_run_ledger() {
  local wt
  wt=$(ns_run_get "$1" | jq -r .worktree) || return 1
  printf '%s/.nightshift/runs/%s/ledger.yaml\n' "$wt" "$1"
}

# ns_run_worktree_path <profile-json> <slug>
ns_run_worktree_path() {
  local tpl repo
  tpl=$(jq -r '.worktrees' <<<"$1")
  repo=$(jq -r '.project' <<<"$1")
  tpl=${tpl//\{repo\}/$repo}
  tpl=${tpl//\{slug\}/$2}
  ns_expand_path "$tpl"
}

# ns_branch_name <pattern> <id> [phase]
ns_branch_name() {
  local pat="$1" id="$2" phase="${3:-}" n
  n=${id#*-}
  pat=${pat//\{slug\}/$id}
  pat=${pat//\{n\}/$n}
  pat=${pat//\{phase\}/$phase}
  printf '%s\n' "$pat"
}

# ns_release_home <ledger>: print the directory of the release the run is pinned to, or
# nothing when the ledger has none. Dies when that release is no longer installed.
ns_release_home() {
  local rel dir
  rel=$("$NS_HOME/bin/ns-ledger" get "$1" '.release // ""' 2>/dev/null) || rel=""
  [ -n "$rel" ] || return 0
  [[ $rel =~ ^v[0-9][0-9A-Za-z._-]*$ ]] && [[ $rel != *..* ]] || ns_die "ledger release '$rel' is not a release tag; refusing to launch it"
  dir="${NS_OPT:-/opt/nightshift}/$rel"
  [ -x "$dir/bin/ns-launch" ] || ns_die "release $rel, which this run started on, is not installed at $dir: install it with bootstrap.sh --upgrade $rel, then resume"
  printf '%s\n' "$dir"
}

# ns_tmux_start <name> <dir> <command>
ns_tmux_start() {
  local name="$1" dir="$2" cmd="$3" v args=()
  for v in $NS_TMUX_ENV_VARS; do
    if [ -n "${!v+x}" ]; then
      args+=(-e "$v=${!v}")
    fi
  done
  # 9>&-: a tmux server started here must not inherit the queue lock
  # env -u GH_TOKEN: the tmux server must not keep the caller's token in its global environment
  env -u GH_TOKEN tmux new-session -d -s "$name" -c "$dir" "${args[@]}" "exec $cmd" 9>&-
}

ns_tmux_has() { tmux has-session -t "=$1" 2>/dev/null; }
ns_tmux_kill() { tmux kill-session -t "=$1"; }
ns_tmux_pane_pid() { tmux list-panes -t "=$1" -F '#{pane_pid}' | head -1; }

# ns_run_log_mtime <id>: epoch seconds of the newest conductor, phase or checks log (or
# checks.rc marker), empty when none
ns_run_log_mtime() {
  local dir f m best=""
  dir="$(ns_config_dir)/logs/$1"
  for f in "$dir"/*.jsonl "$dir"/*.checks.log "$dir"/*.checks.rc; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null) || continue
    if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best=$m; fi
  done
  printf '%s\n' "$best"
}

# ns_run_idle_s <id>: seconds since the newest log was written, empty when there is no log
ns_run_idle_s() {
  local m now
  m=$(ns_run_log_mtime "$1")
  [ -n "$m" ] || return 0
  now=$(date -u -d "$(ns_now)" +%s) || return 0
  [ "$now" -ge "$m" ] || now=$m
  printf '%s\n' $((now - m))
}

# ns_run_checks_busy <id> <pane pid>: true when an "ns-conductor checks <id> ..." process runs
# under the conductor's tmux pane (a long foreground check writes nothing to the JSONL logs)
ns_run_checks_busy() {
  local p q n
  for p in $(pgrep -f -- "ns-conductor checks $1( |\$)" 2>/dev/null); do
    q=$p
    n=0
    while [[ $q =~ ^[0-9]+$ ]] && [ "$q" -gt 1 ] && [ "$n" -lt 64 ]; do
      [ "$q" != "$2" ] || return 0
      q=$(ps -o ppid= -p "$q" 2>/dev/null | tr -d ' ') || q=""
      n=$((n + 1))
    done
  done
  return 1
}

# ns_run_health <id> <state> <gate>: prints ok, dead or "silent <N>m".
# Only a running run with no open gate can be unhealthy: dead when its tmux session or the
# session's pane process is gone, silent when its logs (JSONL, checks log, checks.rc) have not
# grown for NS_SILENT_SECS (1200) and the conductor is not running its checks.
ns_run_health() {
  local id="$1" state="$2" gate="${3:-}" pid idle limit
  if [ "$state" != running ] || { [ -n "$gate" ] && [ "$gate" != null ]; }; then
    printf 'ok\n'
    return 0
  fi
  if ! ns_tmux_has "$id"; then
    printf 'dead\n'
    return 0
  fi
  pid=$(ns_tmux_pane_pid "$id" 2>/dev/null) || pid=""
  if [[ $pid =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
    printf 'dead\n'
    return 0
  fi
  limit=${NS_SILENT_SECS:-1200}
  idle=$(ns_run_idle_s "$id")
  if [ -n "$idle" ] && [ "$idle" -ge "$limit" ] && ! { [[ $pid =~ ^[0-9]+$ ]] && ns_run_checks_busy "$id" "$pid"; }; then
    printf 'silent %sm\n' $((idle / 60))
    return 0
  fi
  printf 'ok\n'
}

# ns_secs_fmt <seconds>: 5m, 2h, 3d
ns_secs_fmt() {
  local s=$1
  if [ "$s" -ge 86400 ]; then
    printf '%sd\n' $((s / 86400))
  elif [ "$s" -ge 3600 ]; then
    printf '%sh\n' $((s / 3600))
  else
    printf '%sm\n' $((s / 60))
  fi
}

# ns_escalation_question <escalation.md>: the "## Question" section as one line, at most 200 chars
ns_escalation_question() {
  local q
  q=$(awk '/^## /{f = ($0 ~ /^## Question[[:space:]]*$/); next} f' "$1" | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  printf '%s\n' "${q:0:200}"
}

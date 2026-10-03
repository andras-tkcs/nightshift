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

# ns_tmux_start <name> <dir> <command>
ns_tmux_start() {
  local name="$1" dir="$2" cmd="$3" v args=()
  for v in $NS_TMUX_ENV_VARS; do
    if [ -n "${!v+x}" ]; then
      args+=(-e "$v=${!v}")
    fi
  done
  tmux new-session -d -s "$name" -c "$dir" "${args[@]}" "exec $cmd"
}

ns_tmux_has() { tmux has-session -t "=$1" 2>/dev/null; }
ns_tmux_kill() { tmux kill-session -t "=$1"; }
ns_tmux_pane_pid() { tmux list-panes -t "=$1" -F '#{pane_pid}' | head -1; }

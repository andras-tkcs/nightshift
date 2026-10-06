# shellcheck shell=bash
# Common helpers for Nightshift executables. Source this file; it defines functions only.

ns_die() {
  printf '%s: %s\n' "${NS_CMD:-ns}" "$1" >&2
  exit "${2:-1}"
}

ns_usage() {
  ns_die "usage: $1" 2
}

ns_warn() {
  printf '%s: warning: %s\n' "${NS_CMD:-ns}" "$1" >&2
}

ns_now() {
  printf '%s\n' "${NS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}

ns_config_dir() { printf '%s\n' "${NS_CONFIG_DIR:-$HOME/.config/ns}"; }
ns_desk_dir() { printf '%s\n' "${NS_DESK_DIR:-/srv/ns-space}"; }
ns_coding_dir() { printf '%s\n' "${NS_CODING_DIR:-$HOME/Coding}"; }
ns_worktree_root() { printf '%s/worktrees\n' "$(ns_coding_dir)"; }

ns_expand_path() {
  local p="$1" coding
  coding="$(ns_coding_dir)"
  # shellcheck disable=SC2088
  if [[ $p == "~" || $p == "~/"* ]]; then
    p="$HOME${p:1}"
  fi
  printf '%s\n' "${p//\{coding\}/$coding}"
}

ns_load_env() {
  local file line name value
  file="$(ns_config_dir)/env"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ ^(export[[:space:]]+)?(NS_[A-Z_]+)=(.*)$ ]]; then
      name="${BASH_REMATCH[2]}"
      value="${BASH_REMATCH[3]}"
      if [[ $value =~ ^\"(.*)\"$ ]] || [[ $value =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi
      if [ -z "${!name+x}" ]; then
        export "$name=$value"
      fi
    fi
  done <"$file"
  return 0
}

ns_require() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || ns_die "needs $c"
  done
}

ns_yaml_json() {
  python3 "$NS_HOME/bin/lib/nsyaml.py" to-json "$1"
}

ns_json_yaml() {
  python3 "$NS_HOME/bin/lib/nsyaml.py" from-json "$1"
}

ns_confirm() {
  local reply
  read -r -p "$1 [y/N] " reply || return 1
  [[ $reply == y || $reply == Y ]]
}

ns_age() {
  local t0 t1 diff
  t0="$(date -u -d "$1" +%s)" || return 1
  t1="$(date -u -d "$(ns_now)" +%s)" || return 1
  diff=$((t1 - t0))
  [ "$diff" -ge 0 ] || diff=0
  if [ "$diff" -ge 86400 ]; then
    printf '%sd\n' $((diff / 86400))
  elif [ "$diff" -ge 3600 ]; then
    printf '%sh\n' $((diff / 3600))
  elif [ "$diff" -ge 60 ]; then
    printf '%sm\n' $((diff / 60))
  else
    printf '%ss\n' "$diff"
  fi
}

ns_has_token() {
  printf '%s' "$1" | grep -Eq '(github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,})'
}

ns_plugin_args() {
  local d
  local -a dirs=()
  [ -n "${NS_PLUGIN_DIRS:-}" ] || return 0
  IFS=: read -r -a dirs <<<"$NS_PLUGIN_DIRS"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    printf '%s\n%s\n' --plugin-dir "$d"
  done
}

# ns_upgrade_guard: refuse (exit 1) to start a conductor while bootstrap.sh holds the upgrade lock
# ${NS_OPT:-/opt/nightshift}/.upgrade.lock. A lock whose bootstrap pid is gone is stale: warn, go on.
ns_upgrade_guard() {
  local f pid
  f="${NS_OPT:-/opt/nightshift}/.upgrade.lock"
  [ -e "$f" ] || return 0
  pid=$(sed -n 's/^pid=//p' "$f" 2>/dev/null | head -n1) || pid=""
  if [[ $pid =~ ^[0-9]+$ ]] && ! ps -p "$pid" >/dev/null 2>&1; then
    ns_warn "ignoring a stale upgrade lock $f (bootstrap pid $pid is gone)"
    return 0
  fi
  ns_die "an upgrade is in progress (bootstrap.sh holds $f): no conductor starts until it ends; try again then"
}

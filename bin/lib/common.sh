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
# ns_private_dir <dir>: create <dir> (missing parents too) readable by the owner only; an
# existing <dir> is set to 700 as well
ns_private_dir() { (umask 077 && mkdir -p "$1") && chmod 700 "$1"; }
# ns_run_logdir <id>: create logs/ and logs/<id> private (700) and print logs/<id>
ns_run_logdir() {
  local d
  d="$(ns_config_dir)/logs"
  ns_private_dir "$d/$1" && chmod 700 "$d" && printf '%s\n' "$d/$1"
}
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

# ASCII letters and digits, spelled out: a range like [A-Za-z0-9] depends on the locale
# (en_US.UTF-8 lets it match é).
NS_ALNUM=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
# token-shaped strings (GitHub, Anthropic, ntfy); match it with LC_ALL=C
NS_TOKEN_RE="(github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|tk_[$NS_ALNUM]{29})"

ns_has_token() {
  printf '%s' "$1" | LC_ALL=C grep -Eq "$NS_TOKEN_RE"
}

# ns_redact_tokens <file>: replace every token-shaped string in <file> with [redacted]
ns_redact_tokens() {
  LC_ALL=C sed -E -i "s/$NS_TOKEN_RE/[redacted]/g" "$1"
}

# ns_ntfy_own_url [url]: true only when url may get the ntfy token: an allowlist, so no
# spelling of ntfy.sh slips through. It must be https://<host>[:port][/] with a host of
# ASCII letters, digits, dots and dashes (no %, @, \ or path), and the host, lowercased and
# without trailing dots, must not be ntfy.sh or a subdomain of it (the public server).
ns_ntfy_own_url() {
  local u="${1:-}" host re="^https://([$NS_ALNUM.-]+)(:[0-9]{1,5})?/?\$"
  [[ $u =~ $re ]] || return 1
  host="${BASH_REMATCH[1],,}"
  while [ "${host%.}" != "$host" ]; do host="${host%.}"; done
  [ -n "$host" ] && [ "$host" != ntfy.sh ] && [[ $host != *.ntfy.sh ]]
}

# ns_ntfy_token: prints the ntfy token from tokens/ntfy, or nothing if there is no such file.
# Dies, never printing the token, if the file is not mode 600 (the ns_token_export message)
# or its first line is not an ntfy token, so the token is safe inside a quoted curl config.
ns_ntfy_token() {
  local file mode tok re="^tk_[$NS_ALNUM]{29}\$"
  file="$(ns_config_dir)/tokens/ntfy"
  [ -f "$file" ] || return 0
  mode=$(stat -c %a "$file")
  [ "$mode" = 600 ] || ns_die "token file $file must be mode 600"
  tok=""
  IFS= read -r tok <"$file" || true
  tok="${tok#"${tok%%[![:space:]]*}"}"
  tok="${tok%"${tok##*[![:space:]]}"}"
  [[ $tok =~ $re ]] ||
    ns_die "token file $file does not hold an ntfy token (tk_ and 29 letters or digits)"
  printf '%s\n' "$tok"
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

# ns_upgrade_locked [quiet]: true while bootstrap.sh holds the upgrade lock
# ${NS_OPT:-/opt/nightshift}/.upgrade.lock. A lock whose pid is not a live bootstrap.sh process
# (gone, or reused by another program) is stale: warn (unless quiet) and return false. A lock
# without a readable pid (being written, or damaged) counts as held; the recovery is to remove
# it by hand once no bootstrap.sh runs.
ns_upgrade_locked() {
  local f pid
  f="${NS_OPT:-/opt/nightshift}/.upgrade.lock"
  [ -e "$f" ] || return 1
  pid=$(head -c 256 "$f" 2>/dev/null | sed -n 's/^pid=//p' | head -n1) || pid=""
  if [[ $pid =~ ^[0-9]+$ ]] && ! ps -o args= -p "$pid" 2>/dev/null | grep -q 'bootstrap\.sh'; then
    [ "${1:-}" = quiet ] || ns_warn "ignoring a stale upgrade lock $f (pid $pid is not a running bootstrap.sh)"
    return 1
  fi
  return 0
}

# ns_upgrade_guard: refuse (exit 1) to start a conductor while bootstrap.sh holds the upgrade lock
ns_upgrade_guard() {
  local f="${NS_OPT:-/opt/nightshift}/.upgrade.lock"
  ! ns_upgrade_locked || ns_die "an upgrade is in progress (bootstrap.sh holds $f): no conductor starts until it ends; try again then (if no bootstrap.sh runs, remove $f as root)"
}

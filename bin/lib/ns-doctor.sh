# shellcheck shell=bash
# summary: check the server, logins and services

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

ns_doctor_help() {
  printf 'usage: ns doctor [--no-claude]\n\n'
  printf 'Check commands, logins, token files and expiry, projects, the desk, services,\n'
  printf 'disk space and auto permission mode. One line per check: ok, warn or FAIL.\n'
  printf 'Exits 1 if any check fails. --no-claude skips the headless auto-mode call.\n'
}

DOC_FAILS=0

doc_ok() { printf 'ok   %s: %s\n' "$1" "$2"; }
doc_warn() { printf 'warn %s: %s\n' "$1" "$2"; }
doc_fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  DOC_FAILS=$((DOC_FAILS + 1))
}

doc_commands() {
  local c missing=() m
  for c in git tmux jq python3 gh claude curl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    doc_fail commands "missing: ${missing[*]}"
  else
    doc_ok commands "git tmux jq python3 gh claude curl"
  fi
  missing=()
  for m in yaml jsonschema; do
    python3 -c "import $m" >/dev/null 2>&1 || missing+=("$m")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    doc_fail python-modules "missing: ${missing[*]}"
  else
    doc_ok python-modules "yaml jsonschema"
  fi
}

doc_gh_auth() {
  if gh auth status >/dev/null 2>&1; then
    doc_ok gh-auth "logged in"
  else
    doc_fail gh-auth "gh auth status failed (run gh auth login)"
  fi
}

# doc_owners: prints the owners of the registered projects, one per line. Only a token
# file named after one of them (tokens/<owner>, as ns_token_export reads it) is a GitHub token.
doc_owners() {
  ns_projects_json 2>/dev/null | jq -r '.[].repo // empty | split("/")[0]' 2>/dev/null |
    grep -E '^[A-Za-z0-9][A-Za-z0-9-]*$' | sort -u || true
}

doc_tokens() {
  local dir f base name mode tok hdr exp now e days owners
  dir="$(ns_config_dir)/tokens"
  if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    doc_warn tokens "no token files in $dir"
    return 0
  fi
  now=$(date -u -d "$(ns_now)" +%s)
  owners=$(doc_owners)
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    name="token $base"
    mode=$(stat -c %a "$f")
    if [ "$mode" != 600 ]; then
      doc_fail "$name" "mode is $mode, must be 600"
      continue
    fi
    # tokens/ntfy is checked by doc_ntfy and never goes to GitHub, nor does any file
    # that is not named after a registered project owner.
    [ "$base" != ntfy ] || continue
    if ! grep -qxF -- "$base" <<<"$owners"; then
      doc_warn "$name" "not named after a registered project owner, not checked"
      continue
    fi
    tok=""
    IFS= read -r tok <"$f" || true
    tok="${tok#"${tok%%[![:space:]]*}"}"
    tok="${tok%"${tok##*[![:space:]]}"}"
    hdr=$(GH_TOKEN="$tok" gh api -i user 2>/dev/null | tr -d '\r' |
      grep -i '^github-authentication-token-expiration:' | head -n1) || hdr=""
    exp="${hdr#*:}"
    exp="${exp#"${exp%%[![:space:]]*}"}"
    if [ -z "$exp" ] || ! e=$(date -u -d "$exp" +%s 2>/dev/null); then
      doc_warn "$name" "mode 600, expiry unknown"
      continue
    fi
    days=$(((e - now) / 86400))
    if [ "$e" -le "$now" ]; then
      doc_fail "$name" "expired"
    elif [ "$days" -lt 14 ]; then
      doc_warn "$name" "expires in $days days"
    else
      doc_ok "$name" "mode 600, expires in $days days"
    fi
  done
}

# doc_ntfy: checks tokens/ntfy (mode 600 is checked by doc_tokens): it must hold an ntfy
# token, and a test publish with it to NS_NTFY_URL must succeed (R-NOT-5).
doc_ntfy() {
  local f out url
  f="$(ns_config_dir)/tokens/ntfy"
  [ -f "$f" ] && [ "$(stat -c %a "$f")" = 600 ] || return 0
  if ! (ns_ntfy_token) >/dev/null 2>&1; then
    doc_fail "token ntfy" "not an ntfy token (tk_ and 29 letters or digits)"
    return 0
  fi
  if [ -z "${NS_NTFY_TOPIC:-}" ]; then
    doc_warn "token ntfy" "mode 600, test publish skipped (NS_NTFY_TOPIC not set)"
    return 0
  fi
  url="${NS_NTFY_URL:-https://ntfy.sh}"
  if out=$("$NS_HOME/bin/ns-notify" "ns doctor: test publish" 2>&1); then
    doc_ok "token ntfy" "mode 600, test publish to $url ok"
  else
    doc_fail "token ntfy" "test publish failed: $(printf '%s\n' "$out" | awk 'NF { printf "%s%s", s, $0; s = "; " }')"
  fi
}

doc_projects() {
  local json p bad=() n
  if ! json=$(ns_projects_json 2>/dev/null); then
    doc_fail projects "projects.yaml does not parse"
    return 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -d "$(ns_expand_path "$p")" ] || bad+=("$p")
  done < <(jq -r '.[].path // empty' <<<"$json")
  n=$(jq 'length' <<<"$json")
  if [ "${#bad[@]}" -gt 0 ]; then
    doc_fail projects "path missing: ${bad[*]}"
  else
    doc_ok projects "$n registered"
  fi
}

doc_desk() {
  local d
  d=$(ns_desk_dir)
  if [ ! -d "$d" ]; then
    doc_fail desk "$d does not exist"
  elif [ ! -w "$d" ]; then
    doc_fail desk "$d is not writable"
  else
    doc_ok desk "$d"
  fi
}

doc_env() {
  local v
  for v in NS_NTFY_TOPIC NS_DESK_URL; do
    if [ -n "${!v:-}" ]; then
      doc_ok "$v" "set"
    else
      doc_warn "$v" "not set (see ~/.config/ns/env)"
    fi
  done
}

doc_services() {
  local u
  if ! command -v systemctl >/dev/null 2>&1; then
    doc_warn services "systemctl not found"
    return 0
  fi
  for u in silverbullet ns-gc.timer ns-health.timer; do
    if systemctl --user is-active "$u" >/dev/null 2>&1; then
      doc_ok "service $u" "active"
    else
      doc_fail "service $u" "inactive"
    fi
  done
  for u in caddy cloudflared; do
    if systemctl is-active "$u" >/dev/null 2>&1; then
      doc_ok "service $u" "active"
    else
      doc_fail "service $u" "inactive"
    fi
  done
}

doc_desk_url() {
  local code
  if [ -z "${NS_DESK_URL:-}" ]; then
    doc_ok desk-url "skipped (NS_DESK_URL not set)"
    return 0
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$NS_DESK_URL" 2>/dev/null) || code=000
  if [[ $code =~ ^[0-9]+$ ]] && [ "$code" -ge 200 ] && [ "$code" -le 403 ]; then
    doc_ok desk-url "HTTP $code"
  else
    doc_fail desk-url "HTTP $code from $NS_DESK_URL"
  fi
}

doc_disk() {
  local pct
  pct=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}') || pct=""
  if ! [[ ${pct:-} =~ ^[0-9]+$ ]]; then
    doc_warn disk "cannot read disk usage"
  elif [ "$pct" -ge 95 ]; then
    doc_fail disk "${pct}% used"
  elif [ "$pct" -ge 80 ]; then
    doc_warn disk "${pct}% used"
  else
    doc_ok disk "${pct}% used"
  fi
}

doc_reboot() {
  if [ -e "${NS_REBOOT_FILE:-/var/run/reboot-required}" ]; then
    doc_warn reboot "reboot required"
  else
    doc_ok reboot "not required"
  fi
}

doc_auto() {
  local skip="$1" mode out
  if [ "$skip" = 1 ]; then
    doc_warn auto-mode "skipped (--no-claude)"
    return 0
  fi
  mode="${NS_WORKER_MODE:-$(ns_config_get worker_mode auto)}"
  if [ "$mode" != auto ]; then
    doc_ok auto-mode "worker mode is $mode (not checked)"
    return 0
  fi
  if out=$("$NS_HOME/bin/ns-conductor" check-auto 2>&1); then
    doc_ok auto-mode "works in a headless call"
  else
    out=$(printf '%s' "$out" | tail -n1)
    doc_fail auto-mode "${out:-auto mode failed}; fix it, or set NS_WORKER_MODE=bypassPermissions in ~/.config/ns/env after reading docs/security.md, section \"Worker permission mode\""
  fi
}

doc_runs() {
  local id ledger n=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ledger=$(ns_run_ledger "$id")
    [ -f "$ledger" ] || continue
    if [ "$("$NS_HOME/bin/ns-ledger" get "$ledger" .state 2>/dev/null)" = running ] && ! ns_tmux_has "$id"; then
      doc_warn runs "run $id has no session: ns resume $id"
      n=$((n + 1))
    fi
  done < <(ns_runs_json | jq -r '.[] | select(.archived | not) | .id')
  [ "$n" -gt 0 ] || doc_ok runs "every running run has a session"
}

ns_doctor_main() {
  local skip=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-claude) skip=1 ;;
      *) ns_usage "ns doctor [--no-claude]" ;;
    esac
    shift
  done
  doc_commands
  doc_gh_auth
  doc_tokens
  doc_ntfy
  doc_projects
  doc_desk
  doc_env
  doc_services
  doc_desk_url
  doc_disk
  doc_reboot
  doc_auto "$skip"
  doc_runs
  [ "$DOC_FAILS" -eq 0 ]
}

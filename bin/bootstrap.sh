#!/usr/bin/env bash
# bootstrap.sh: turn a phase-2 server into a Nightshift runtime (spec section 14).
# Runs as root. "bootstrap.sh --check" changes nothing and works as any user.
# shellcheck disable=SC2329  # check_<n>/apply_<n> are called by name from the step loop
set -euo pipefail

NS_HOME="${NS_HOME:-$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")}"

# Overridable for tests: a prefix for every absolute system path, the service user,
# its home (used as given, not prefixed) and the templates directory.
NS_BS_ROOT="${NS_BS_ROOT:-}"
NS_USER="${NS_USER:-ns}"
NS_BS_TEMPLATES="${NS_BS_TEMPLATES:-$NS_HOME/templates}"
if [ -z "${NS_USER_HOME:-}" ]; then
  _passwd="$(getent passwd "$NS_USER" 2>/dev/null || true)"
  if [ -n "$_passwd" ]; then
    NS_USER_HOME="$NS_BS_ROOT$(printf '%s' "$_passwd" | cut -d: -f6)"
  else
    NS_USER_HOME="$NS_BS_ROOT/home/$NS_USER"
  fi
fi

STEPS="1 2 3 4 5"
N=11
CHECK_MSG=""
APPLY_MSG=""

usage() {
  cat <<'EOF'
usage: bootstrap.sh [--check | --upgrade <tag>]

Turns a phase-2 server into a Nightshift runtime. Idempotent; run as root.
  --check          report each step (ok, would change, needs you, unknown); change nothing
  --upgrade <tag>  install a release tag (not available yet)
  --help           show this text
Exit status: 0 everything ok, 1 something to do or needs you, 2 usage error.
EOF
}

P() { printf '%s%s' "$NS_BS_ROOT" "$1"; }

step_name() {
  case "$1" in
    1) echo "Caddy and desk certificates" ;;
    2) echo "Desk folder /srv/ns-space" ;;
    3) echo "SilverBullet" ;;
    4) echo "cloudflared tunnel" ;;
    5) echo "Cloudflare SSH CA (optional)" ;;
    *) echo "step $1" ;;
  esac
}

# Prompt helpers; secrets are never echoed or logged (R-BS-1).
ask() { # ask <prompt> -> REPLY
  printf '%s ' "$1" >&2
  read -r REPLY || REPLY=""
}
ask_secret() { # ask_secret <prompt> -> REPLY
  printf '%s ' "$1" >&2
  read -rs REPLY || REPLY=""
  printf '\n' >&2
}

as_ns() {
  local uid
  uid="$(id -u "$NS_USER")"
  runuser -u "$NS_USER" -- env "XDG_RUNTIME_DIR=/run/user/$uid" "$@"
}

ts_host() {
  tailscale status --json 2>/dev/null | jq -r '.Self.DNSName | rtrimstr(".")' 2>/dev/null
}

render_caddyfile() { # render_caddyfile <host>
  sed "s/@TS_HOST@/$1/g" "$NS_BS_TEMPLATES/caddy/Caddyfile.tmpl"
}

# ---- step 1: Caddy -------------------------------------------------------

check_1() {
  local todo=() host f
  if ! command -v caddy >/dev/null 2>&1; then
    todo+=("install caddy")
  fi
  host="$(ts_host || true)"
  if [ -z "$host" ] || [ "$host" = null ]; then
    CHECK_MSG="needs you: tailscale is not connected (run tailscale up)"
    return 1
  fi
  f="$(P /etc/caddy/Caddyfile)"
  if [ ! -e "$f" ]; then
    todo+=("write /etc/caddy/Caddyfile")
  elif [ ! -r "$f" ]; then
    CHECK_MSG="unknown: /etc/caddy/Caddyfile is not readable"
    return 1
  elif ! render_caddyfile "$host" | cmp -s - "$f"; then
    todo+=("update /etc/caddy/Caddyfile")
  fi
  f="$(P /etc/default/tailscaled)"
  if [ -e "$f" ] && [ ! -r "$f" ]; then
    CHECK_MSG="unknown: /etc/default/tailscaled is not readable"
    return 1
  fi
  if ! grep -qs '^TS_PERMIT_CERT_UID=caddy$' "$f"; then
    todo+=("set TS_PERMIT_CERT_UID=caddy")
  fi
  if [ "${#todo[@]}" -eq 0 ]; then
    CHECK_MSG="ok"
    return 0
  fi
  CHECK_MSG="would change: $(printf '%s, ' "${todo[@]}" | sed 's/, $//')"
  return 1
}

apply_1() {
  local host dir
  host="$(ts_host || true)"
  if [ -z "$host" ] || [ "$host" = null ]; then
    APPLY_MSG="needs you: tailscale is not connected (run tailscale up)"
    return 1
  fi
  if ! command -v caddy >/dev/null 2>&1; then
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
    mkdir -p "$(P /usr/share/keyrings)" "$(P /etc/apt/sources.list.d)"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor --yes -o "$(P /usr/share/keyrings/caddy-stable-archive-keyring.gpg)"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      >"$(P /etc/apt/sources.list.d/caddy-stable.list)"
    apt-get update
    apt-get install -y caddy
  fi
  dir="$(P /etc/caddy)"
  mkdir -p "$dir"
  render_caddyfile "$host" >"$dir/Caddyfile.new"
  chmod 644 "$dir/Caddyfile.new"
  mv "$dir/Caddyfile.new" "$dir/Caddyfile"
  mkdir -p "$(P /etc/default)"
  if ! grep -qs '^TS_PERMIT_CERT_UID=caddy$' "$(P /etc/default/tailscaled)"; then
    printf 'TS_PERMIT_CERT_UID=caddy\n' >>"$(P /etc/default/tailscaled)"
    systemctl restart tailscaled
  fi
  systemctl reload caddy || systemctl restart caddy
  APPLY_MSG="changed"
}

# ---- step 2: /srv/ns-space ----------------------------------------------

check_2() {
  local d got
  d="$(P /srv/ns-space)"
  if [ ! -e "$d" ]; then
    CHECK_MSG="would change: create /srv/ns-space ($NS_USER:caddy, 2750)"
    return 1
  fi
  if ! got="$(stat -c '%U:%G %a' "$d" 2>/dev/null)"; then
    CHECK_MSG="unknown: cannot stat /srv/ns-space"
    return 1
  fi
  if [ "$got" != "$NS_USER:caddy 2750" ]; then
    CHECK_MSG="would change: /srv/ns-space is $got, want $NS_USER:caddy 2750"
    return 1
  fi
  CHECK_MSG="ok"
}

apply_2() {
  local d
  d="$(P /srv/ns-space)"
  install -d -o "$NS_USER" -g caddy -m 2750 "$d"
  chown "$NS_USER:caddy" "$d"
  chmod 2750 "$d"
  APPLY_MSG="changed"
}

# ---- step 3: SilverBullet ------------------------------------------------

sb_unit() { printf '%s/.config/systemd/user/silverbullet.service' "$NS_USER_HOME"; }
sb_link() { printf '%s/.config/systemd/user/default.target.wants/silverbullet.service' "$NS_USER_HOME"; }

check_3() {
  local todo=()
  [ -x "$NS_USER_HOME/opt/silverbullet/silverbullet" ] || todo+=("install SilverBullet binary")
  [ -d "$NS_USER_HOME/sb-data" ] || todo+=("create ~$NS_USER/sb-data")
  if ! cmp -s "$NS_BS_TEMPLATES/systemd/silverbullet.service" "$(sb_unit)" 2>/dev/null; then
    todo+=("install user unit")
  fi
  [ -L "$(sb_link)" ] || todo+=("enable the unit")
  if [ "${#todo[@]}" -eq 0 ]; then
    CHECK_MSG="ok"
    return 0
  fi
  CHECK_MSG="would change: $(printf '%s, ' "${todo[@]}" | sed 's/, $//')"
  return 1
}

apply_3() {
  local zip
  command -v unzip >/dev/null 2>&1 || apt-get install -y unzip
  as_ns mkdir -p "$NS_USER_HOME/opt/silverbullet" "$NS_USER_HOME/sb-data" \
    "$NS_USER_HOME/.config/systemd/user"
  if [ ! -x "$NS_USER_HOME/opt/silverbullet/silverbullet" ]; then
    zip="$NS_USER_HOME/opt/silverbullet/silverbullet-server-linux-x86_64.zip"
    as_ns curl -fsSL -o "$zip" \
      https://github.com/silverbulletmd/silverbullet/releases/latest/download/silverbullet-server-linux-x86_64.zip
    as_ns unzip -o -d "$NS_USER_HOME/opt/silverbullet" "$zip"
    as_ns chmod +x "$NS_USER_HOME/opt/silverbullet/silverbullet"
  fi
  install -o "$NS_USER" -m 644 "$NS_BS_TEMPLATES/systemd/silverbullet.service" "$(sb_unit)"
  as_ns systemctl --user daemon-reload
  as_ns systemctl --user enable --now silverbullet
  APPLY_MSG="changed"
}

# ---- step 4: cloudflared -------------------------------------------------

check_4() {
  if ! command -v cloudflared >/dev/null 2>&1 \
    || [ ! -e "$(P /etc/systemd/system/cloudflared.service)" ]; then
    CHECK_MSG="needs you: tunnel token"
    return 1
  fi
  CHECK_MSG="ok"
}

apply_4() {
  local deb token
  if ! command -v cloudflared >/dev/null 2>&1; then
    deb="$(mktemp --suffix=.deb)"
    curl -fsSL -o "$deb" \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    apt-get install -y "$deb"
    rm -f "$deb"
  fi
  if [ ! -t 0 ]; then
    APPLY_MSG="needs you: tunnel token (run bootstrap.sh in a terminal)"
    return 1
  fi
  ask_secret "Cloudflare tunnel token (not shown):"
  token="$REPLY"
  REPLY=""
  if [ -z "$token" ]; then
    APPLY_MSG="needs you: tunnel token"
    return 1
  fi
  cloudflared service install "$token"
  token=""
  APPLY_MSG="changed"
}

# ---- step 5: Cloudflare SSH CA (optional) --------------------------------

check_5() {
  if [ -e "$(P /etc/ssh/cloudflare_ca.pub)" ]; then
    CHECK_MSG="ok"
  else
    CHECK_MSG="ok (not configured)"
  fi
  return 0
}

apply_5() {
  local ca principal
  if [ ! -t 0 ]; then
    APPLY_MSG="ok (not configured)"
    return 0
  fi
  ask "Set up the browser terminal (option B)? [y/N]"
  case "$REPLY" in
    y | Y | yes | YES) ;;
    *)
      APPLY_MSG="ok (not configured)"
      return 0
      ;;
  esac
  ask "Cloudflare SSH CA public key:"
  ca="$REPLY"
  ask "Principal (the name Cloudflare puts in the certificate) [$NS_USER]:"
  principal="${REPLY:-$NS_USER}"
  if [ -z "$ca" ]; then
    APPLY_MSG="needs you: the CA public key"
    return 1
  fi
  mkdir -p "$(P /etc/ssh/principals)" "$(P /etc/ssh/sshd_config.d)"
  printf '%s\n' "$ca" >"$(P /etc/ssh/cloudflare_ca.pub)"
  printf '%s\n' "$principal" >"$(P "/etc/ssh/principals/$NS_USER")"
  cat >"$(P /etc/ssh/sshd_config.d/cloudflare.conf)" <<EOF
TrustedUserCAKeys /etc/ssh/cloudflare_ca.pub
Match User $NS_USER
    AuthorizedPrincipalsFile /etc/ssh/principals/%u
EOF
  if ! sshd -t; then
    rm -f "$(P /etc/ssh/sshd_config.d/cloudflare.conf)" "$(P /etc/ssh/cloudflare_ca.pub)"
    APPLY_MSG="needs you: sshd rejected the configuration; nothing was changed"
    return 1
  fi
  systemctl reload ssh
  APPLY_MSG="changed"
}

# ---- main ------------------------------------------------------------------

mode=apply
while [ $# -gt 0 ]; do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --check) mode=check ;;
    --upgrade)
      echo "bootstrap.sh: --upgrade is not available yet" >&2
      exit 2
      ;;
    *)
      echo "bootstrap.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$mode" = apply ] && [ "$(id -u)" -ne 0 ]; then
  echo "bootstrap.sh: run as root, or use --check" >&2
  exit 2
fi

rc=0
for n in $STEPS; do
  name="$(step_name "$n")"
  if check_"$n"; then
    # An optional step that is not configured is ok, but a real run offers to set it up.
    if [ "$mode" = check ] || [ "$CHECK_MSG" != "ok (not configured)" ]; then
      printf '[%s/%s] %s: %s\n' "$n" "$N" "$name" "$CHECK_MSG"
      continue
    fi
  fi
  if [ "$mode" = check ]; then
    printf '[%s/%s] %s: %s\n' "$n" "$N" "$name" "$CHECK_MSG"
    rc=1
    continue
  fi
  case "$CHECK_MSG" in
    unknown*)
      printf '[%s/%s] %s: %s\n' "$n" "$N" "$name" "$CHECK_MSG"
      rc=1
      continue
      ;;
  esac
  if apply_"$n"; then
    printf '[%s/%s] %s: %s\n' "$n" "$N" "$name" "$APPLY_MSG"
  else
    printf '[%s/%s] %s: %s\n' "$n" "$N" "$name" "$APPLY_MSG"
    rc=1
  fi
done
exit "$rc"

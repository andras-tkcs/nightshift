#!/usr/bin/env bash
# bootstrap.sh: turn a phase-2 server into a Nightshift runtime (spec section 14).
# Runs as root. "bootstrap.sh --check" changes nothing and works as any user.
# shellcheck disable=SC2329  # check_<n>/apply_<n> are called by name from the step loop
set -euo pipefail

NS_HOME="${NS_HOME:-$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")}"

# Test-only switches (never set them on a real run): NS_BS_TEST=1 lets a non-root user
# run the apply path (skips the root rule and the chown to root), NS_BS_STEPS="8 9"
# limits the steps, NS_REPO_URL points step 8 at a local bare repo.
#
# Overridable for tests: a prefix for every absolute system path, the service user,
# its home (used as given, not prefixed) and the templates directory.
NS_BS_ROOT="${NS_BS_ROOT:-}"
NS_USER="${NS_USER:-ns}"
NS_BS_TEMPLATES_GIVEN="${NS_BS_TEMPLATES:-}"
NS_BS_TEMPLATES="${NS_BS_TEMPLATES:-$NS_HOME/templates}"
if [ -z "${NS_USER_HOME:-}" ]; then
  _passwd="$(getent passwd "$NS_USER" 2>/dev/null || true)"
  if [ -n "$_passwd" ]; then
    NS_USER_HOME="$NS_BS_ROOT$(printf '%s' "$_passwd" | cut -d: -f6)"
  else
    NS_USER_HOME="$NS_BS_ROOT/home/$NS_USER"
  fi
fi

STEPS="${NS_BS_STEPS:-1 2 3 4 5 6 7 8 9 10 11}"
N=11
NS_REPO_URL="${NS_REPO_URL:-https://github.com/andras-tkcs/nightshift.git}"
RELEASE_LINKS="ns ns-conductor ns-notify ns-gh ns-ledger ns-launch"
TARGET_TAG=""
CHECK_MSG=""
APPLY_MSG=""

usage() {
  cat <<'EOF'
usage: bootstrap.sh [--check | --upgrade <tag>] [--force]

Turns a phase-2 server into a Nightshift runtime. Idempotent; run as root.
  --check          report each step (ok, would change, needs you, unknown) and the runs'
                   jobs; change nothing
  --upgrade <tag>  install release <tag> under /opt/nightshift, re-pin the plugins and
                   reinstall the timers (runs steps 8, 9 and 10 only; earlier releases
                   stay for rollback)
  --force          proceed although a job is live
  --help           show this text
Every mode but --check refuses while a job is live (a run's tmux session, conductor or
worker process), and holds /opt/nightshift/.upgrade.lock while it runs, so that ns new,
ns resume and ns approve start no conductor meanwhile.
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
    6) echo "hcloud CLI and lab context" ;;
    7) echo "ntfy topic and desk settings" ;;
    8) echo "Release install /opt/nightshift" ;;
    9) echo "Plugin marketplace and plugins" ;;
    10) echo "ns-gc and ns-health timers and Remote Control" ;;
    11) echo "ns doctor" ;;
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
  runuser -u "$NS_USER" -- env "XDG_RUNTIME_DIR=/run/user/$uid" "HOME=$NS_USER_HOME" \
    "PATH=$NS_USER_HOME/.local/bin:$PATH" "$@"
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
  [ -e "$(P "/var/lib/systemd/linger/$NS_USER")" ] || todo+=("enable lingering for $NS_USER")
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
  # The user service must run without a login session.
  loginctl enable-linger "$NS_USER"
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

# ---- step 6: hcloud CLI and the lab context --------------------------------

hc_bin() { printf '%s/.local/bin/hcloud' "$NS_USER_HOME"; }
hc_cfg() { printf '%s/.config/hcloud/cli.toml' "$NS_USER_HOME"; }

check_6() {
  local todo=()
  [ -x "$(hc_bin)" ] || todo+=("install hcloud")
  grep -qs '^[[:space:]]*name = "nightshift-lab"' "$(hc_cfg)" || todo+=("create context nightshift-lab")
  if [ "${#todo[@]}" -eq 0 ]; then
    CHECK_MSG="ok"
    return 0
  fi
  CHECK_MSG="would change: $(printf '%s, ' "${todo[@]}" | sed 's/, $//')"
  return 1
}

apply_6() {
  if [ ! -x "$(hc_bin)" ]; then
    as_ns mkdir -p "$NS_USER_HOME/.local/bin"
    # shellcheck disable=SC2016  # $1 is for the inner shell
    as_ns sh -c 'curl -fsSL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz -C "$1" hcloud' \
      sh "$NS_USER_HOME/.local/bin"
  fi
  if ! grep -qs '^[[:space:]]*name = "nightshift-lab"' "$(hc_cfg)"; then
    ask_secret "Hetzner nightshift-lab project token (not shown):"
    if [ -z "$REPLY" ]; then
      REPLY=""
      APPLY_MSG="needs you: lab project token"
      return 1
    fi
    # The token travels in the environment only, never on a command line.
    HCLOUD_TOKEN="$REPLY"
    REPLY=""
    export HCLOUD_TOKEN
    if ! runuser -w HCLOUD_TOKEN -u "$NS_USER" -- env "HOME=$NS_USER_HOME" \
      "$(hc_bin)" context create --token-from-env nightshift-lab >/dev/null; then
      unset HCLOUD_TOKEN
      APPLY_MSG="needs you: hcloud rejected the token"
      return 1
    fi
    unset HCLOUD_TOKEN
  fi
  APPLY_MSG="changed"
}

# ---- step 7: ntfy topic and desk settings -----------------------------------

env_file() { printf '%s/.config/ns/env' "$NS_USER_HOME"; }
env_has() { grep -qsE "^(export )?$1=." "$(env_file)"; }

check_7() {
  local todo=() f k mode
  f="$(env_file)"
  if [ ! -e "$f" ]; then
    CHECK_MSG="would change: create ~$NS_USER/.config/ns/env"
    return 1
  fi
  if [ ! -r "$f" ]; then
    CHECK_MSG="unknown: ~$NS_USER/.config/ns/env is not readable"
    return 1
  fi
  for k in NS_NTFY_TOPIC NS_DESK_URL; do
    env_has "$k" || todo+=("set $k")
  done
  mode="$(stat -c %a "$f" 2>/dev/null || true)"
  [ "$mode" = 600 ] || todo+=("chmod 600")
  if [ "${#todo[@]}" -eq 0 ]; then
    CHECK_MSG="ok"
    return 0
  fi
  CHECK_MSG="would change: $(printf '%s, ' "${todo[@]}" | sed 's/, $//')"
  return 1
}

apply_7() {
  local f topic desk hc first=0
  f="$(env_file)"
  as_ns mkdir -p "$(dirname "$f")"
  if [ ! -e "$f" ]; then as_ns tee "$f" </dev/null >/dev/null; fi
  as_ns chmod 600 "$f"
  if env_has NS_NTFY_TOPIC; then
    topic="$(grep -E '^(export )?NS_NTFY_TOPIC=' "$f" | tail -1 | sed -E "s/^(export )?NS_NTFY_TOPIC=//; s/^'//; s/'\$//")"
  else
    topic="ns-$(openssl rand -hex 8)"
    as_ns tee -a "$f" >/dev/null <<<"export NS_NTFY_TOPIC='$topic'"
  fi
  if ! env_has NS_DESK_URL; then
    ask "NS_DESK_URL, the address of the desk (for example https://ns-desk.example.com):"
    desk="${REPLY//\'/}"
    REPLY=""
    if [ -z "$desk" ]; then
      printf 'ntfy topic (subscribe to it in the ntfy app): %s\n' "$topic"
      APPLY_MSG="needs you: NS_DESK_URL"
      return 1
    fi
    as_ns tee -a "$f" >/dev/null <<<"export NS_DESK_URL='$desk'"
    first=1
  fi
  if [ "$first" -eq 1 ] && ! env_has NS_HEALTHCHECK_URL; then
    ask_secret "NS_HEALTHCHECK_URL, optional, press Enter to skip (not shown):"
    hc="${REPLY//\'/}"
    REPLY=""
    if [ -n "$hc" ]; then
      as_ns tee -a "$f" >/dev/null <<<"export NS_HEALTHCHECK_URL='$hc'"
    fi
  fi
  printf 'ntfy topic (subscribe to it in the ntfy app): %s\n' "$topic"
  APPLY_MSG="changed"
}

# ---- step 8: the release under /opt/nightshift ----------------------------------

newest_tag() { # prints the newest v* tag, nothing when there is none
  git ls-remote --tags --refs "$NS_REPO_URL" 'v*' 2>/dev/null \
    | sed 's|.*refs/tags/||' | sort -V | tail -n 1
}

tag_exists() { # tag_exists <tag>
  [ -n "$(git ls-remote --tags --refs "$NS_REPO_URL" "refs/tags/$1" 2>/dev/null)" ]
}

current_tag() { # prints the release current points at, nothing when unset
  local l
  l="$(readlink "$(P /opt/nightshift/current)" 2>/dev/null || true)"
  if [ -n "$l" ]; then basename "$l"; fi
  return 0
}

check_8() {
  local tag cur todo=() n
  if ! git ls-remote "$NS_REPO_URL" HEAD >/dev/null 2>&1; then
    CHECK_MSG="unknown: cannot reach $NS_REPO_URL"
    return 1
  fi
  tag="$(newest_tag)"
  if [ -z "$tag" ]; then
    CHECK_MSG='needs you: no release tag yet (docs/development.md, "Releasing")'
    return 1
  fi
  cur="$(current_tag)"
  if [ "$cur" != "$tag" ] || [ ! -d "$(P "/opt/nightshift/$tag")" ]; then
    todo+=("install release $tag")
  fi
  for n in $RELEASE_LINKS; do
    if [ "$(readlink "$(P "/usr/local/bin/$n")" 2>/dev/null || true)" != "/opt/nightshift/current/bin/$n" ] \
      || [ ! -e "$(P "/opt/nightshift/current/bin/$n")" ]; then
      todo+=("link $n")
    fi
  done
  if [ "${#todo[@]}" -eq 0 ]; then
    CHECK_MSG="ok"
    return 0
  fi
  CHECK_MSG="would change: $(printf '%s, ' "${todo[@]}" | sed 's/, $//')"
  return 1
}

apply_8() {
  local tag base tmp n
  tag="${TARGET_TAG:-$(newest_tag)}"
  if [ -z "$tag" ]; then
    APPLY_MSG='needs you: no release tag yet (docs/development.md, "Releasing")'
    return 1
  fi
  base="$(P /opt/nightshift)"
  mkdir -p "$base" "$(P /usr/local/bin)"
  if [ ! -d "$base/$tag" ]; then
    tmp="$base/.clone-$tag.$$"
    rm -rf "$tmp"
    if ! git clone --quiet --branch "$tag" --depth 1 "$NS_REPO_URL" "$tmp" 2>/dev/null; then
      rm -rf "$tmp"
      APPLY_MSG="needs you: clone of $tag failed"
      return 1
    fi
    if { [ -n "${NS_BS_TEST:-}" ] || chown -R root:root "$tmp"; } && chmod -R go-w "$tmp" \
      && mv "$tmp" "$base/$tag"; then
      :
    else
      rm -rf "$tmp"
      APPLY_MSG="needs you: installing $tag failed (chown, chmod or mv)"
      return 1
    fi
  fi
  if [ ! -x "$base/$tag/bin/ns" ]; then
    APPLY_MSG="needs you: release $tag has no executable bin/ns; current left unchanged"
    return 1
  fi
  ln -sfn "$tag" "$base/current.new"
  mv -T "$base/current.new" "$base/current"
  for n in $RELEASE_LINKS; do
    ln -sfn "/opt/nightshift/current/bin/$n" "$(P "/usr/local/bin/$n")"
  done
  APPLY_MSG="changed (release $tag)"
}

# ---- step 9: marketplace and plugins, as ns ----------------------------------------

pin_file() { printf '%s/.config/ns/release-pin' "$NS_USER_HOME"; }

repo_slug() { # owner/repo from the origin URL of the installed release
  local url
  url="$(git -C "$(P /opt/nightshift/current)" remote get-url origin 2>/dev/null || true)"
  url="${url%.git}"
  printf '%s\n' "$url" | sed -E 's|^.*[:/]([^/:]+/[^/]+)$|\1|'
}

check_9() {
  local tag slug
  tag="$(current_tag)"
  if [ -z "$tag" ]; then
    CHECK_MSG="would change: add the marketplace (needs the release from step 8 first)"
    return 1
  fi
  slug="$(repo_slug)"
  if [ "$(cat "$(pin_file)" 2>/dev/null || true)" != "$slug#$tag" ]; then
    CHECK_MSG="would change: pin the marketplace to $slug#$tag, install ns and ns-python"
    return 1
  fi
  CHECK_MSG="ok"
}

apply_9() {
  local tag slug pin old
  tag="$(current_tag)"
  if [ -z "$tag" ]; then
    APPLY_MSG="needs you: no release installed (step 8 first)"
    return 1
  fi
  slug="$(repo_slug)"
  pin="$slug#$tag"
  old="$(cat "$(pin_file)" 2>/dev/null || true)"
  if [ "$old" != "$pin" ]; then
    if [ -n "$old" ]; then as_ns claude plugin marketplace remove nightshift; fi
    as_ns claude plugin marketplace add "$pin"
  fi
  as_ns claude plugin install ns@nightshift --scope user
  as_ns claude plugin install ns-python@nightshift --scope user
  as_ns mkdir -p "$(dirname "$(pin_file)")"
  as_ns tee "$(pin_file)" >/dev/null <<<"$pin"
  APPLY_MSG="changed (pinned to $pin)"
}

# ---- step 10: ns-gc timer and the Remote Control session ----------------------------------

ud() { printf '%s/.config/systemd/user' "$NS_USER_HOME"; }

has_project() { grep -qs 'path:' "$NS_USER_HOME/.config/ns/projects.yaml"; }

check_10() {
  local todo=() u
  for u in ns-gc.service ns-gc.timer ns-health.service ns-health.timer; do
    cmp -s "$NS_BS_TEMPLATES/systemd/$u" "$(ud)/$u" 2>/dev/null || todo+=("install $u")
  done
  [ -L "$(ud)/timers.target.wants/ns-gc.timer" ] || todo+=("enable ns-gc.timer")
  [ -L "$(ud)/timers.target.wants/ns-health.timer" ] || todo+=("enable ns-health.timer")
  if has_project && ! as_ns tmux has-session -t rc 2>/dev/null; then
    todo+=("start the Remote Control session")
  fi
  if [ "${#todo[@]}" -eq 0 ]; then
    if has_project; then CHECK_MSG="ok"; else CHECK_MSG="ok (no project yet; ns up starts it)"; fi
    return 0
  fi
  CHECK_MSG="would change: $(printf '%s, ' "${todo[@]}" | sed 's/, $//')"
  return 1
}

# templates_dir: an upgrade runs from the old release, so step 10 takes the units of the
# release it installs (unless NS_BS_TEMPLATES is given)
templates_dir() {
  local r
  r="$(P "/opt/nightshift/$TARGET_TAG")/templates"
  if [ -z "$NS_BS_TEMPLATES_GIVEN" ] && [ -n "$TARGET_TAG" ] && [ -d "$r/systemd" ]; then
    printf '%s\n' "$r"
  else
    printf '%s\n' "$NS_BS_TEMPLATES"
  fi
}

apply_10() {
  local u tpl
  tpl="$(templates_dir)"
  as_ns mkdir -p "$(ud)"
  for u in ns-gc.service ns-gc.timer ns-health.service ns-health.timer; do
    as_ns tee "$(ud)/$u" <"$tpl/systemd/$u" >/dev/null
  done
  as_ns systemctl --user daemon-reload
  as_ns systemctl --user enable --now ns-gc.timer
  as_ns systemctl --user enable --now ns-health.timer
  if has_project; then
    as_ns tmux has-session -t rc 2>/dev/null || as_ns "$(P /usr/local/bin/ns)" up >/dev/null || true
    APPLY_MSG="changed"
  else
    APPLY_MSG="changed (no project yet; ns up starts the Remote Control session)"
  fi
}

# ---- step 11: ns doctor ----------------------------------------------------------------------

check_11() {
  if [ ! -e "$(P /opt/nightshift/current/bin/ns)" ]; then
    CHECK_MSG="would change: run ns doctor (after step 8)"
    return 1
  fi
  CHECK_MSG="ok"
}

apply_11() {
  local out rc=0
  out="$(runuser -l "$NS_USER" -c '[ ! -r ~/.config/ns/env ] || . ~/.config/ns/env; ns doctor' 2>&1)" || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  if [ "$rc" -eq 0 ]; then
    APPLY_MSG="ok (ns doctor passed)"
    return 0
  fi
  APPLY_MSG="needs you: ns doctor reported problems (exit $rc, see above)"
  return 1
}

# ---- live jobs (#78) ---------------------------------------------------------

RUN_ID_RE='^[a-z][a-z0-9]{0,9}-([0-9]+|x[0-9]+|onboard)$'

cfg_dir() { printf '%s\n' "${NS_CONFIG_DIR:-$NS_USER_HOME/.config/ns}"; }

# ns_tmux <args>: tmux as the service user (its server holds the run sessions)
ns_tmux() {
  id -u "$NS_USER" >/dev/null 2>&1 || return 1
  if [ "$(id -u)" = "$(id -u "$NS_USER")" ]; then tmux "$@"; else as_ns tmux "$@"; fi
}

pid_alive() { # pid_alive <pid>: running and not a zombie (works for any user's process)
  local st
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" || return 1
  [ -n "$st" ] && [[ $st != Z* ]]
}

# live_pid <id> <sessions>: the pid of a live job of run <id>, "-" for a session without a
# pane pid; nothing when none is live. A tmux session, the conductor pid file ns-launch
# writes, or a worker pid file in <config>/workers counts.
live_pid() {
  local id="$1" sessions="$2" cfg pid f base
  cfg="$(cfg_dir)"
  if grep -qxF -- "$id" <<<"$sessions"; then
    pid="$(ns_tmux list-panes -t "=$id" -F '#{pane_pid}' 2>/dev/null | head -n 1 || true)"
    [[ $pid =~ ^[0-9]+$ ]] || pid=-
    printf '%s\n' "$pid"
    return 0
  fi
  pid="$(head -n 1 "$cfg/logs/$id/conductor.pid" 2>/dev/null || true)"
  if pid_alive "$pid" && ps -o args= -p "$pid" 2>/dev/null | grep -q 'ns-launch'; then
    printf '%s\n' "$pid"
    return 0
  fi
  for f in "$cfg/workers/$id"--*.pid; do
    [ -f "$f" ] || continue
    base="${f%.pid}"
    [ ! -e "$base.exit" ] || continue
    pid="$(sed -n 's/^pid=//p' "$f" | head -n 1)"
    if pid_alive "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 0
}

# job_report: sets LIVE ("id  state  release  pid" for each run with a live job), DEAD (runs
# that are running in their ledger with nothing alive) and IDLE (other runs not done, stopped
# or failed: at a gate, queued, parked; they resume on their own release)
job_report() {
  local cfg sessions id wt l st rel pid seen=' ' f base
  LIVE=""
  DEAD=""
  IDLE=""
  cfg="$(cfg_dir)"
  sessions="$(ns_tmux ls -F '#{session_name}' 2>/dev/null | sed 's/:.*//' | grep -E "$RUN_ID_RE" || true)"
  if [ -f "$cfg/runs.yaml" ]; then
    while IFS=$'\t' read -r id wt; do
      [ -n "$id" ] || continue
      seen="$seen$id "
      st=-
      rel=-
      l="$wt/.nightshift/runs/$id/ledger.yaml"
      if [ -f "$l" ]; then
        read -r st rel < <(python3 "$NS_HOME/bin/lib/nsyaml.py" to-json "$l" 2>/dev/null \
          | jq -r '"\(.state // "-") \(.release // "-")"' 2>/dev/null || echo "unknown -") || true
      fi
      pid="$(live_pid "$id" "$sessions")"
      if [ -n "$pid" ]; then
        LIVE="$LIVE$id  $st  $rel  $pid"$'\n'
      elif [ "$st" = running ]; then
        DEAD="$DEAD$id  $st  $rel"$'\n'
      else
        case "$st" in
          done | stopped | failed) ;;
          *) IDLE="$IDLE$id  $st  $rel"$'\n' ;;
        esac
      fi
    done < <(python3 "$NS_HOME/bin/lib/nsyaml.py" to-json "$cfg/runs.yaml" \
      | jq -r '.runs // [] | .[] | select(.archived | not) | [.id, .worktree] | @tsv')
  fi
  # live jobs of runs that are not registered (yet): a session or a worker
  for id in $sessions; do
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    LIVE="$LIVE$id  -  -  $(live_pid "$id" "$sessions")"$'\n'
  done
  for f in "$cfg"/workers/*.pid; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    id="${base%%--*}"
    case "$seen" in *" $id "*) continue ;; esac
    pid="$(live_pid "$id" "")"
    [ -z "$pid" ] || { seen="$seen$id "; LIVE="$LIVE$id  -  -  $pid"$'\n'; }
  done
  return 0
}

# print_jobs [<show live>]: the warning and information lines of job_report
print_jobs() {
  if [ "${1:-}" = live ] && [ -n "$LIVE" ]; then
    echo "Live jobs (id, state, release, pid); an install change refuses while they run:"
    printf '%s' "$LIVE" | sed 's/^/  /'
  fi
  if [ -n "$DEAD" ]; then
    echo "Warning: running in the ledger but nothing is alive (id, state, release):"
    printf '%s' "$DEAD" | while read -r id st rel; do
      printf '  %s  %s  %s  looks dead: ns kill %s or ns stop %s\n' "$id" "$st" "$rel" "$id" "$id"
    done
  fi
  if [ -n "$IDLE" ]; then
    echo "Not running now (id, state, release); each resumes on its own release:"
    printf '%s' "$IDLE" | sed 's/^/  /'
  fi
  return 0
}

LOCK_MADE_DIR=""
LOCK_FILE=""

# take_lock: create /opt/nightshift/.upgrade.lock (ns new, ns resume and ns approve refuse while
# it exists); refuse while another live bootstrap holds it. Removed on exit.
take_lock() {
  local base opid d
  base="$(P /opt/nightshift)"
  # remember the topmost directory made here, so a refusal leaves the tree as it was
  d="$base"
  while [ ! -d "$d" ]; do
    LOCK_MADE_DIR="$d"
    d="$(dirname "$d")"
  done
  mkdir -p "$base"
  LOCK_FILE="$base/.upgrade.lock"
  if [ -e "$LOCK_FILE" ]; then
    opid="$(sed -n 's/^pid=//p' "$LOCK_FILE" 2>/dev/null | head -n 1 || true)"
    if pid_alive "$opid"; then
      echo "bootstrap.sh: another bootstrap.sh (pid $opid) holds $LOCK_FILE; wait for it" >&2
      LOCK_FILE=""
      release_lock
      exit 1
    fi
    rm -f "$LOCK_FILE"
  fi
  if ! (set -C && printf 'pid=%s\nstarted=%s\nmode=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$mode" >"$LOCK_FILE") 2>/dev/null; then
    echo "bootstrap.sh: cannot create $LOCK_FILE (another bootstrap.sh?)" >&2
    LOCK_FILE=""
    release_lock
    exit 1
  fi
  chmod 644 "$LOCK_FILE"
  trap release_lock EXIT
}

release_lock() {
  [ -z "$LOCK_FILE" ] || rm -f "$LOCK_FILE"
  # only directories that are still empty: a step that installed something keeps them
  if [ -n "$LOCK_MADE_DIR" ]; then
    find "$LOCK_MADE_DIR" -depth -type d -empty -delete 2>/dev/null || true
  fi
  return 0
}

# ---- main ------------------------------------------------------------------

mode=apply
upgrade_tag=""
force=false
while [ $# -gt 0 ]; do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --check) mode=check ;;
    --force) force=true ;;
    --upgrade)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "bootstrap.sh: --upgrade needs a tag" >&2
        exit 2
      fi
      mode=upgrade
      upgrade_tag="$2"
      shift
      ;;
    *)
      echo "bootstrap.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$mode" != check ] && [ "$(id -u)" -ne 0 ] && [ -z "${NS_BS_TEST:-}" ]; then
  echo "bootstrap.sh: run as root, or use --check" >&2
  exit 2
fi

if [ "$mode" = upgrade ]; then
  if ! tag_exists "$upgrade_tag"; then
    echo "bootstrap.sh: tag $upgrade_tag not found in $NS_REPO_URL" >&2
    exit 1
  fi
  TARGET_TAG="$upgrade_tag"
  STEPS="8 9 10"
fi

# One guard for every mode that changes the install (#78): take the lock first, so no
# conductor starts after the check, then refuse while a job is live unless --force.
if [ "$mode" != check ]; then
  take_lock
  job_report
  if [ -n "$LIVE" ]; then
    if [ "$force" != true ]; then
      {
        echo "bootstrap.sh: refusing to change the install while jobs are live (id, state, release, pid):"
        printf '%s' "$LIVE" | sed 's/^/  /'
        echo "Wait for them (ns drain parks running runs), or pass --force."
      } >&2
      exit 1
    fi
    echo "bootstrap.sh: --force: changing the install although jobs are live (id, state, release, pid):" >&2
    printf '%s' "$LIVE" | sed 's/^/  /' >&2
  fi
  print_jobs
fi

rc=0
for n in $STEPS; do
  name="$(step_name "$n")"
  if [ "$mode" = upgrade ]; then
    CHECK_MSG=""
  elif check_"$n"; then
    # An optional step that is not configured is ok, but a real run offers to set it up;
    # the doctor step always runs in a real run so its verdict is shown every time.
    if [ "$mode" = check ] || { [ "$CHECK_MSG" != "ok (not configured)" ] && [ "$n" != 11 ]; }; then
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
  # Run the step in a subshell with errexit on. It must not sit in an if/||/&& condition,
  # or bash would switch errexit off inside the function. The message comes back by file.
  msgf="$(mktemp)"
  set +e
  (
    set -Eeuo pipefail
    trap 'printf "%s" "$APPLY_MSG" >"$msgf"' EXIT
    trap '[ -n "$APPLY_MSG" ] || APPLY_MSG="needs you: ${BASH_COMMAND%% *} failed"' ERR
    APPLY_MSG=""
    apply_"$n"
  )
  step_rc=$?
  set -e
  APPLY_MSG="$(cat "$msgf")"
  rm -f "$msgf"
  if [ "$step_rc" -ne 0 ] && [ -z "$APPLY_MSG" ]; then
    APPLY_MSG="needs you: step $n failed"
  fi
  printf '[%s/%s] %s: %s\n' "$n" "$N" "$name" "$APPLY_MSG"
  if [ "$step_rc" -ne 0 ]; then rc=1; fi
done
if [ "$mode" = check ]; then
  job_report
  print_jobs live
fi
exit "$rc"

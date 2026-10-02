# shellcheck shell=bash
# Ledger helpers shared by bin/ns-ledger and its callers. Source common.sh first.
# Functions that read or write a ledger expect the caller to hold the flock on
# <ledger>.lock (ns-ledger does this for every subcommand).

NS_LEDGER_SCHEMA="${NS_HOME:?NS_HOME must be set}/schema/ledger.schema.json"

# ns_ledger_worktree <ledger>: the git worktree that holds the ledger.
ns_ledger_worktree() {
  git -C "$(dirname "$1")" rev-parse --show-toplevel
}

# ns_ledger_error <file>: print the first parse or schema error of a ledger file
# (nothing when valid). Returns 1 when invalid.
ns_ledger_error() {
  local out
  out="$(python3 "$NS_HOME/bin/lib/nsyaml.py" validate "$1" "$NS_LEDGER_SCHEMA" 2>&1)" || true
  [ -n "$out" ] || return 0
  out="${out%%$'\n'*}"
  out="${out#nsyaml: }"
  printf '%s\n' "${out#"$1": }"
  return 1
}

# ns_ledger_write <ledger>: read JSON on stdin, validate, replace the file atomically.
ns_ledger_write() {
  local ledger="$1" tmp err
  tmp="$ledger.tmp.$$.json"
  cat >"$tmp"
  if ! err="$(ns_ledger_error "$tmp")"; then
    rm -f "$tmp"
    ns_die "ledger $ledger: $err; not written"
  fi
  ns_json_yaml "$ledger" <"$tmp" || { rm -f "$tmp"; ns_die "ledger $ledger: write failed"; }
  rm -f "$tmp"
}

# ns_ledger_recover <ledger>: try to restore the committed version. Returns 1 if none.
ns_ledger_recover() {
  local ledger="$1" dir wt rel sha tmp
  dir="$(readlink -f "$(dirname "$ledger")")"
  wt="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  rel="${dir#"$wt"/}/$(basename "$ledger")"
  tmp="$ledger.tmp.$$.committed"
  git -C "$wt" show "HEAD:$rel" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  if ! ns_ledger_error "$tmp" >/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  sha="$(git -C "$wt" rev-parse --short HEAD)"
  ns_yaml_json "$tmp" | jq -c --arg now "$(ns_now)" --arg sha "$sha" \
    '.updated = $now | .events += [{time: $now, type: "recovered", note: ("ledger was corrupt; restored from " + $sha)}]' |
    ns_ledger_write "$ledger" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  ns_warn "ledger $ledger was corrupt; restored from $sha"
}

# ns_ledger_read <ledger>: print the ledger as compact JSON, recovering if needed.
ns_ledger_read() {
  local ledger="$1"
  [ -f "$ledger" ] || ns_die "no such ledger: $ledger"
  if ! ns_ledger_error "$ledger" >/dev/null; then
    ns_ledger_recover "$ledger" ||
      ns_die "ledger $ledger is corrupt and has no valid committed version"
  fi
  ns_yaml_json "$ledger"
}

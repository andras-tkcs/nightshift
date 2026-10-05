# shellcheck shell=bash
# Ledger helpers shared by bin/ns-ledger and its callers. Source common.sh first.
# Functions that read or write a ledger expect the caller to hold the flock on
# <ledger>.lock (ns-ledger does this for every subcommand).

NS_LEDGER_SCHEMA="${NS_HOME:?NS_HOME must be set}/schema/ledger.schema.json"

# ns_ledger_worktree <ledger>: the git worktree that holds the ledger.
ns_ledger_worktree() {
  git -C "$(dirname "$1")" rev-parse --show-toplevel
}

# ns_ledger_check <file>: print every parse or schema error of a ledger file, one per line.
ns_ledger_check() {
  local out
  out="$(python3 "$NS_HOME/bin/lib/nsyaml.py" validate "$1" "$NS_LEDGER_SCHEMA" 2>&1)" || true
  [ -z "$out" ] || printf '%s\n' "$out" | sed -e 's/^nsyaml: //' -e "s|^$1: ||"
}

# ns_ledger_unknown_keys <file>: print the unknown top-level keys of a ledger file, one per line.
# An unknown key is schema drift (a newer or older release wrote the ledger), not corruption.
ns_ledger_unknown_keys() {
  ns_ledger_check "$1" | ns_ledger_keys_filter
}

# ns_ledger_keys_filter: stdin is ns_ledger_check output; print the unknown top-level keys.
ns_ledger_keys_filter() {
  sed -n "s/^\$: Additional properties are not allowed (\(.*\) w\(as\|ere\) unexpected)\$/\1/p" |
    tr ',' '\n' | sed -e "s/^ *'//" -e "s/' *\$//"
}

# ns_ledger_error <file>: print the first hard error (parse error, missing field, wrong type) of
# a ledger file; unknown top-level keys are not errors. Returns 1 when invalid.
ns_ledger_error() {
  local out
  out="$(ns_ledger_check "$1" | grep -v '^\$: Additional properties are not allowed' || true)"
  [ -n "$out" ] || return 0
  printf '%s\n' "${out%%$'\n'*}"
  return 1
}

# ns_ledger_guard <ledger>: refuse to write a live run's ledger from a dev checkout.
# NS_RUN_ID and NS_LEDGER mark the live run; ns-launch exports NS_RUN_HOME, the home that launched it.
# Only that home may write the run's ledger. Without NS_RUN_HOME, only an installed release may.
ns_ledger_guard() {
  local ledger="$1" live
  [ -n "${NS_RUN_ID:-}" ] && [ -n "${NS_LEDGER:-}" ] || return 0
  live="$(readlink -f "$NS_LEDGER" 2>/dev/null || printf '%s' "$NS_LEDGER")"
  [ "$(readlink -f "$ledger" 2>/dev/null || printf '%s' "$ledger")" = "$live" ] || return 0
  if [ -n "${NS_RUN_HOME:-}" ]; then
    [ "$(readlink -f "$NS_HOME")" != "$(readlink -f "$NS_RUN_HOME")" ] || return 0
  else
    case "$(readlink -f "$NS_HOME")/" in
      "${NS_OPT:-/opt/nightshift}"/*) return 0 ;;
    esac
  fi
  ns_die "refusing to write $ledger: it belongs to live run $NS_RUN_ID and NS_HOME=$NS_HOME is not the home that launched it (${NS_RUN_HOME:-${NS_OPT:-/opt/nightshift}}); test new code against a temp ledger"
}

# ns_ledger_write <ledger>: read JSON on stdin, validate, replace the file atomically.
ns_ledger_write() {
  local ledger="$1" tmp err
  ns_ledger_guard "$ledger"
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
  local chk err key
  chk="$(ns_ledger_check "$ledger")"
  err="$(printf '%s\n' "$chk" | grep -v '^\$: Additional properties are not allowed' | grep -v '^$' | head -n1 || true)"
  if [ -n "$err" ]; then
    ns_ledger_recover "$ledger" ||
      ns_die "ledger $ledger is corrupt and has no valid committed version: $err; run: ns-ledger validate $ledger"
  fi
  while IFS= read -r key; do
    [ -z "$key" ] || ns_warn "ledger has unknown field $key; kept"
  done < <(printf '%s\n' "$chk" | ns_ledger_keys_filter)
  ns_yaml_json "$ledger"
}

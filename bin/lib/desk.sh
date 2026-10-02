# shellcheck shell=bash
# Review desk helpers. Source this file; it defines functions only.
# Needs common.sh, config.sh and runs.sh.

# ns_desk_run_dir <repo> <id>: the desk folder of one run
ns_desk_run_dir() {
  printf '%s/%s/runs/%s\n' "$(ns_desk_dir)" "$1" "$2"
}

# ns_desk_check_html <file>: return 1 when the HTML is not self-contained (R-DSK-2)
ns_desk_check_html() {
  if grep -Eiq '<script[^>]*[[:space:]]src[[:space:]]*=|<link[^>]*href[[:space:]]*=[[:space:]]*["'\'']?http|@import' "$1"; then
    return 1
  fi
  return 0
}

# ns_desk_index <repo>: regenerate <desk>/<repo>/index.md from the non-archived runs' ledgers
ns_desk_index() {
  local repo="$1" root out id ledger rdir tier state gate docs name
  root="$(ns_desk_dir)/$repo"
  out="$root/index.md"
  mkdir -p "$root"
  {
    printf '# %s runs\n\n' "$repo"
    printf 'Updated %s by ns publish.\n\n' "$(ns_now)"
    printf '| Run | Tier | State | Gate | Documents |\n'
    printf '|---|---|---|---|---|\n'
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      rdir="$root/runs/$id"
      [ -d "$rdir" ] || continue
      ledger=$(ns_run_ledger "$id")
      tier="-"
      state="?"
      gate="-"
      if [ -f "$ledger" ]; then
        tier=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.tier // "-"')
        state=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.state // "?"')
        gate=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.gate // "-"')
      fi
      docs=""
      if [ -f "$rdir/.published" ]; then
        while IFS=$'\t' read -r name _; do
          [ -n "$name" ] || continue
          docs="${docs:+$docs, }[$name](runs/$id/$name)"
        done <"$rdir/.published"
      fi
      printf '| %s | %s | %s | %s | %s |\n' "$id" "$tier" "$state" "$gate" "$docs"
    done < <(ns_runs_json | jq -r --arg p "$repo" '.[] | select((.archived | not) and .project == $p) | .id')
  } >"$out.tmp"
  mv "$out.tmp" "$out"
}

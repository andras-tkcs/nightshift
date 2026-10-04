# shellcheck shell=bash
# Review desk helpers. Source this file; it defines functions only.
# Needs common.sh, config.sh and runs.sh.

# ns_desk_run_dir <repo> <id>: the desk folder of one run
ns_desk_run_dir() {
  printf '%s/%s/runs/%s\n' "$(ns_desk_dir)" "$1" "$2"
}

# ns_desk_check_html <file>: return 1 when the HTML is not self-contained (R-DSK-2).
# A deny-list over the whole file (grep -z, so matches span lines), case-insensitive.
# The CSP header on the desk listeners is the second layer (templates/caddy/Caddyfile.tmpl).
ns_desk_check_html() {
  local f="$1" tag remote r rc
  # a tag body: any characters but ">", or a quoted string taken whole so a quoted ">" does not end the tag
  tag='([^>]|"[^"]*"|'\''[^'\'']*'\'')*'
  # "=" then a value that leaves the page: http:, https:, //, \, /\ or an entity (&...)
  remote='[[:space:]]*=[[:space:]]*["'\'']?[[:space:]]*(https?:|//|\\|/\\|&)'
  local -a rules=(
    # any script, inline or not, any case
    '<script'
    # tags that only load things
    '<(link|base|iframe|frame|object|embed)[[:space:]/>]'
    # src= with a remote value, on any element
    '[[:space:]/"'\'']src'"$remote"
    # srcset is a list of URLs; a self-contained page uses src="data:..."
    '[[:space:]/"'\'']srcset[[:space:]]*='
    # href= (or xlink:href=) with a remote value on any tag but <a>
    '<([b-z][a-z0-9:-]*|a[a-z0-9:-]+)'"$tag"'[[:space:]/"'\''](xlink:)?href'"$remote"
    # CSS imports
    '@import'
    # CSS url() with a remote value
    'url\([[:space:]]*["'\'']?[[:space:]]*(https?:|//|\\|/\\|&)'
    # inline event handlers (on...=) inside a tag
    '<[a-z][a-z0-9:-]*'"$tag"'[[:space:]/"'\'']on[a-z]+[[:space:]]*='
    # javascript: URLs, anywhere
    'javascript:'
    # <meta http-equiv=refresh>
    'http-equiv[[:space:]]*=[[:space:]]*["'\'']?[[:space:]]*refresh'
  )
  # a NUL byte would split grep -z records and reopen the multiline bypass (also refuses UTF-16)
  [ "$(LC_ALL=C tr -cd '\000' <"$f" | wc -c)" -eq 0 ] || return 1
  for r in "${rules[@]}"; do
    rc=0
    LC_ALL=C grep -Eiqz -e "$r" -- "$f" || rc=$?
    [ "$rc" -eq 1 ] || return 1
  done
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

# shellcheck shell=bash
# summary: put documents on the review desk

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/desk.sh"

ns_publish_help() {
  printf 'usage: ns publish <id> <file>[:<name>]...\n\n'
  printf 'Copy documents from the run worktree to the review desk (a leading RUN/ means\n'
  printf '.nightshift/runs/<id>/), refresh index.md and send a notification. Names must\n'
  printf 'match [A-Za-z0-9._-]+.(md|html|yaml|env). HTML must be self-contained.\n'
}

ns_publish_main() {
  local u="ns publish <id> <file>[:<name>]..."
  [ $# -ge 2 ] && [[ $1 != -* ]] || ns_usage "$u"
  local id="$1" entry wt repo desk rdir spec file name src abs rel sum ledger gate n url first
  shift
  entry=$(ns_run_get "$id") || ns_die "unknown run $id"
  wt=$(jq -r .worktree <<<"$entry")
  repo=$(jq -r .project <<<"$entry")
  desk=$(ns_desk_dir)
  [ -d "$desk" ] || ns_die "desk $desk not found: run bootstrap.sh or set NS_DESK_DIR"
  [ -d "$wt" ] || ns_die "run worktree $wt is missing"
  wt=$(realpath "$wt")
  rdir=$(ns_desk_run_dir "$repo" "$id")

  # validate everything before copying anything
  local -a srcs=() names=()
  for spec in "$@"; do
    file="$spec"
    name=""
    if [[ $spec == *:* ]]; then
      file="${spec%:*}"
      name="${spec##*:}"
    fi
    [ -n "$file" ] || ns_die "empty file in '$spec'"
    case "$file" in
      RUN/*) file=".nightshift/runs/$id/${file#RUN/}" ;;
    esac
    case "$file" in
      /*) abs="$file" ;;
      *) abs="$wt/$file" ;;
    esac
    abs=$(realpath -m "$abs")
    case "$abs" in
      "$wt"/*) ;;
      *) ns_die "$spec: not inside the run worktree" ;;
    esac
    [ -f "$abs" ] || ns_die "$spec: no such file"
    [ -n "$name" ] || name=$(basename "$abs")
    [[ $name =~ ^[A-Za-z0-9._-]+\.(md|html|yaml|env)$ ]] || ns_die "$name: name must match [A-Za-z0-9._-]+.(md|html|yaml|env)"
    if [[ $name == *.html ]] && ! ns_desk_check_html "$abs"; then
      ns_die "$name: HTML must be self-contained (no scripts, no external resources)"
    fi
    if ns_has_token "$(cat "$abs")"; then
      ns_die "$name: looks like it contains a token; not published"
    fi
    srcs+=("$abs")
    names+=("$name")
  done

  mkdir -p "$rdir"
  touch "$rdir/.published"
  for n in "${!names[@]}"; do
    name="${names[$n]}"
    src="${srcs[$n]}"
    rel="${src#"$wt"/}"
    install -m 0640 "$src" "$rdir/$name"
    sum=$(sha256sum "$rdir/$name" | awk '{print $1}')
    awk -F'\t' -v n="$name" '$1 != n' "$rdir/.published" >"$rdir/.published.tmp"
    printf '%s\t%s\t%s\n' "$name" "$rel" "$sum" >>"$rdir/.published.tmp"
    mv "$rdir/.published.tmp" "$rdir/.published"
  done
  ns_desk_index "$repo"

  first="${names[0]}"
  url=""
  [ -z "${NS_DESK_URL:-}" ] || url="$NS_DESK_URL/$repo/runs/$id/$first"
  ledger=$(ns_run_ledger "$id")
  gate=""
  if [ -f "$ledger" ]; then
    gate=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.gate // ""') || gate=""
  fi
  local -a nargs=()
  if [ -n "$gate" ]; then
    nargs=("$id: gate $gate needs you")
  else
    nargs=("$id: ${#names[@]} document(s) published")
  fi
  [ -z "$url" ] || nargs+=("$url")
  "$NS_HOME/bin/ns-notify" "${nargs[@]}" || ns_warn "notification failed"
  printf 'published %s to %s\n' "${names[*]}" "$rdir"
}

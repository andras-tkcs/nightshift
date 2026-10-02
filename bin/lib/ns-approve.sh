# shellcheck shell=bash
# summary: commit desk edits and release a gate

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/desk.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/profile.sh"

ns_approve_help() {
  printf 'usage: ns approve <id> [--yes]\n\n'
  printf 'Show what you changed on the review desk, commit the desk versions of the\n'
  printf 'Markdown and YAML documents to the run branch and release the gate. --yes skips\n'
  printf 'the question and is only allowed for projects added with --sandbox. An\n'
  printf 'onboarding run (<prefix>-onboard) opens a pull request instead.\n'
}

# ns_approve_onboard_path <name>: repo path of an onboarding desk file, empty if not mapped
ns_approve_onboard_path() {
  case "$1" in
    project-profile.yaml) printf '.claude/project-profile.yaml\n' ;;
    ns-github.env) printf '.claude/ns-github.env\n' ;;
    *-invariants.md) printf '.claude/skills/%s/SKILL.md\n' "${1%-invariants.md}-invariants" ;;
  esac
}

# ns_approve_onboard <id> <project-json> <ledger> <gate> <desk run dir>
ns_approve_onboard() {
  local id="$1" project="$2" ledger="$3" gate="$4" rdir="$5"
  local repo path prefix branch base pr_wt body name rel url files=()
  repo=$(jq -r .repo <<<"$project")
  path=$(jq -r .path <<<"$project")
  prefix=$(jq -r .prefix <<<"$project")
  branch=$(jq -r '.branch // ""' <<<"$project")
  base=$(ns_profile_json "$path" "$prefix" "$branch" 2>/dev/null | jq -r '.git.base_branch // "main"') || base=main
  [ -n "$base" ] || base=main
  ns_token_export "${repo%%/*}"
  pr_wt="$(ns_worktree_root)/${repo#*/}-$id--pr"
  body=$(mktemp)

  git -C "$path" fetch -q origin "$base" || ns_die "could not fetch origin $base in $path"
  git -C "$path" fetch -q origin nightshift/onboard 2>/dev/null || true
  git -C "$path" worktree prune
  if [ -d "$pr_wt" ]; then
    git -C "$path" worktree remove --force "$pr_wt"
  fi
  mkdir -p "$(dirname "$pr_wt")"
  if git -C "$path" rev-parse -q --verify refs/remotes/origin/nightshift/onboard >/dev/null; then
    git -C "$path" worktree add -q -B nightshift/onboard "$pr_wt" origin/nightshift/onboard || ns_die "could not create worktree $pr_wt"
  else
    git -C "$path" worktree add -q -B nightshift/onboard "$pr_wt" "origin/$base" || ns_die "could not create worktree $pr_wt"
  fi

  {
    printf 'Onboards %s to Nightshift. Review the files, then merge.\n\n' "$repo"
    printf 'Files added:\n\n'
  } >"$body"
  while IFS=$'\t' read -r name _; do
    [ -n "$name" ] || continue
    rel=$(ns_approve_onboard_path "$name")
    [ -n "$rel" ] || continue
    mkdir -p "$pr_wt/$(dirname "$rel")"
    cp "$rdir/$name" "$pr_wt/$rel"
    files+=("$rel")
    # shellcheck disable=SC2016
    printf -- '- `%s`\n' "$rel" >>"$body"
  done <"$rdir/.published"
  if [ "${#files[@]}" -eq 0 ]; then
    git -C "$path" worktree remove --force "$pr_wt"
    rm -f "$body"
    ns_die "$id: no onboarding documents are published"
  fi
  printf '\nGuesses to check:\n\n' >>"$body"
  for rel in "${files[@]}"; do
    grep -n '# guess:' "$pr_wt/$rel" | sed "s|^|$rel:|" >>"$body" || true
  done
  git -C "$pr_wt" add -f -- "${files[@]}"
  git -C "$pr_wt" commit -q -m "ns: onboard $repo" -m "Approved-By: owner"
  git -C "$pr_wt" push -q -u origin nightshift/onboard || ns_die "could not push nightshift/onboard"
  if ! url=$(gh pr create --base "$base" --head nightshift/onboard --title "Onboard $repo to Nightshift" --body-file "$body"); then
    git -C "$path" worktree remove --force "$pr_wt"
    rm -f "$body"
    ns_die "gh pr create failed"
  fi
  url=$(tail -n 1 <<<"$url")
  git -C "$path" worktree remove --force "$pr_wt"
  rm -f "$body"

  "$NS_HOME/bin/ns-ledger" set "$ledger" ".gate=null | .state=\"done\" | .step=\"done\" | .pr=$(jq -n --arg u "$url" '$u')"
  "$NS_HOME/bin/ns-ledger" event "$ledger" approved "gate $gate"
  "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push
  printf 'opened %s; merge it, then ns new works for %s\n' "$url" "$repo"
}

ns_approve_main() {
  local u="ns approve <id> [--yes]"
  local id="" yes=false a
  for a in "$@"; do
    case "$a" in
      --yes) yes=true ;;
      -*) ns_usage "$u" ;;
      *)
        [ -z "$id" ] || ns_usage "$u"
        id="$a"
        ;;
    esac
  done
  [ -n "$id" ] || ns_usage "$u"
  local entry wt ledger gate pname project rdir name src item onboard=false
  local -a changed=() srcs=()
  entry=$(ns_run_get "$id") || ns_die "unknown run $id"
  wt=$(jq -r .worktree <<<"$entry")
  pname=$(jq -r .project <<<"$entry")
  ledger=$(ns_run_ledger "$id")
  [ -f "$ledger" ] || ns_die "no ledger at $ledger"
  gate=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.gate // ""')
  if [ -z "$gate" ]; then
    printf '%s is not waiting at a gate; nothing to approve\n' "$id"
    return 0
  fi
  project=$(ns_project_by_name "$pname") || ns_die "project $pname is not registered"
  if [ "$yes" = true ] && [ "$(jq -r '.sandbox // false' <<<"$project")" != true ]; then
    printf '%s\n' "--yes is only allowed for projects added with --sandbox" >&2
    exit 2
  fi
  [[ $id == *-onboard ]] && onboard=true
  rdir=$(ns_desk_run_dir "$pname" "$id")
  [ -f "$rdir/.published" ] || ns_die "$id: nothing is published on the desk; run ns publish first"
  [ -d "$wt" ] || ns_die "run worktree $wt is missing: ns resume $id rebuilds it"

  # 3. diffs
  while IFS=$'\t' read -r name src _; do
    [ -n "$name" ] || continue
    case "$name" in
      *.md | *.yaml) ;;
      *.env) [ "$onboard" = true ] || continue ;;
      *) continue ;;
    esac
    if [ -f "$rdir/$name" ] && ! cmp -s "$wt/$src" "$rdir/$name"; then
      diff -u --label "branch:$src" --label "desk:$name" "$wt/$src" "$rdir/$name" || true
      changed+=("$name"$'\t'"$src")
    else
      printf 'no changes: %s\n' "$name"
    fi
  done <"$rdir/.published"

  # 4. confirm
  if [ "$yes" = false ]; then
    if ! ns_confirm "Commit the desk versions and release gate $gate of $id?"; then
      printf 'Nothing changed.\n'
      exit 1
    fi
  fi

  if [ "$onboard" = true ]; then
    ns_approve_onboard "$id" "$project" "$ledger" "$gate" "$rdir"
    return 0
  fi

  # 5. commit desk edits
  for item in "${changed[@]}"; do
    name="${item%%$'\t'*}"
    src="${item#*$'\t'}"
    cp "$rdir/$name" "$wt/$src"
    srcs+=("$src")
  done
  if [ "${#srcs[@]}" -gt 0 ]; then
    git -C "$wt" add -f -- "${srcs[@]}"
  fi
  git -C "$wt" commit -q --allow-empty -m "ns: approve $id gate $gate" -m "Approved-By: owner"

  # 6. release the gate
  "$NS_HOME/bin/ns-ledger" set "$ledger" '.gate=null | .state="queued"'
  "$NS_HOME/bin/ns-ledger" event "$ledger" approved "gate $gate"
  "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push
  # shellcheck source=/dev/null
  source "$NS_HOME/bin/lib/ns-resume.sh"
  ns_resume_main "$id"
  printf 'approved gate %s of %s\n' "$gate" "$id"
}

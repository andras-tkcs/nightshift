# shellcheck shell=bash
# shellcheck disable=SC2154  # the run context variables are set by load_run in bin/ns-conductor
# ns-conductor subcommands of the phase loop: branches, checks, report, review rounds, merge,
# gates, finish, pause. Sourced by bin/ns-conductor, which provides load_run, lg, jstr,
# phase_update and the run context (id, run, wt, ledger, profile, plan_doc, logdir).

conductor_loop_usage() {
  printf '  fix-branch    <id>\n'
  printf '  feature       <id>\n'
  printf '  stack-base    <id>\n'
  printf '  checks        <id> <phase|feature> [--force]\n'
  printf '  report        <id> <phase> [--rerun]\n'
  printf '  note          <id> <text> | --file <file>\n'
  printf '  review-round  <id> <phase> <approve|changes>\n'
  printf '  merge         <id> <phase>\n'
  printf '  gate          <id> <1|1.5|2> <file>[:<name>]...\n'
  printf '  finish        <id> --pr <url>\n'
  printf '  pause         <id>\n'
  printf '  unpause       <id>\n'
}

# loop_tier: the run's tier, T2 when unset
loop_tier() {
  local t
  t=$(lg get "$ledger" '.tier // empty')
  printf '%s\n' "${t:-T2}"
}

# loop_code_wt: worktree of the code branch. It follows the ledger's feature_branch: <id>--fix when
# that is the profile's fix branch, <id>--feature when it is anything else; while unset the tier
# decides (<id>--fix for T0/T1, <id>--feature otherwise), so a retier after fix-branch cannot
# move it.
loop_code_wt() {
  local fb
  fb=$(lg get "$ledger" '.feature_branch // empty')
  if [ -n "$fb" ]; then
    if [ "$fb" = "$(ns_branch_name "$(jq -r '.git.fix_branch' <<<"$profile")" "$id")" ]; then
      ns_run_worktree_path "$profile" "$id--fix"
    else
      ns_run_worktree_path "$profile" "$id--feature"
    fi
    return
  fi
  case "$(loop_tier)" in
    T0 | T1) ns_run_worktree_path "$profile" "$id--fix" ;;
    *) ns_run_worktree_path "$profile" "$id--feature" ;;
  esac
}

# loop_checks_canon <target>: `fix` is `feature` when both name the code worktree (T0/T1);
# any other target is unchanged
loop_checks_canon() {
  if [ "$1" = fix ] && [ "$(ns_run_worktree_path "$profile" "$id--fix")" = "$(loop_code_wt)" ]; then
    printf 'feature\n'
  else
    printf '%s\n' "$1"
  fi
}

# loop_add_worktree <worktree> <branch> <base>: create the worktree on the branch when absent;
# sets CREATED=1 (a variable of the caller) when it did
loop_add_worktree() {
  local dir="$1" branch="$2" base="$3"
  [ ! -d "$dir" ] || return 0
  git -C "$wt" fetch -q origin || ns_die "could not fetch origin"
  mkdir -p "$(dirname "$dir")"
  if git -C "$wt" show-ref -q --verify "refs/heads/$branch"; then
    git -C "$wt" worktree add -q "$dir" "$branch"
  elif git -C "$wt" show-ref -q --verify "refs/remotes/origin/$branch"; then
    git -C "$wt" worktree add -q -b "$branch" "$dir" "origin/$branch"
  else
    git -C "$wt" worktree add -q -b "$branch" "$dir" "origin/$base"
  fi
  CREATED=1
}

conductor_fix_branch() {
  [ $# -eq 1 ] || ns_usage "ns-conductor fix-branch <id>"
  local base branch dir CREATED=0
  load_run "$1"
  budget_guard fix-branch || return
  base=$(jq -r '.git.base_branch' <<<"$profile")
  branch=$(ns_branch_name "$(jq -r '.git.fix_branch' <<<"$profile")" "$id")
  dir=$(ns_run_worktree_path "$profile" "$id--fix")
  loop_add_worktree "$dir" "$branch" "$base"
  if [ "$CREATED" -eq 1 ]; then
    ns_stack_setup "$dir" "$profile" >&2 || ns_die "setup failed in $dir"
  fi
  if [ "$(lg get "$ledger" '.feature_branch // empty')" != "$branch" ]; then
    lg set "$ledger" ".feature_branch = $(jstr "$branch")"
    lg checkpoint "$ledger"
  fi
  printf '%s\n' "$dir"
}

conductor_feature() {
  [ $# -eq 1 ] || ns_usage "ns-conductor feature <id>"
  local base branch dir plan_branch CREATED=0
  local -a files=()
  load_run "$1"
  base=$(jq -r '.git.base_branch' <<<"$profile")
  branch=$(ns_branch_name "$(jq -r '.git.feature_branch' <<<"$profile")" "$id")
  plan_branch=$(ns_branch_name "$(jq -r '.git.plan_branch' <<<"$profile")" "$id")
  dir=$(ns_run_worktree_path "$profile" "$id--feature")
  loop_add_worktree "$dir" "$branch" "$base"
  git -C "$dir" fetch -q origin "$base" || ns_die "could not fetch origin $base"
  mapfile -d '' -t files < <(git -C "$dir" diff -z --name-only --diff-filter=AM "origin/$base...$plan_branch" -- . ':(exclude).nightshift')
  if [ "${#files[@]}" -gt 0 ]; then
    git -C "$dir" checkout -q "$plan_branch" -- "${files[@]}"
    if [ -n "$(git -C "$dir" status --porcelain -- "${files[@]}")" ]; then
      git -C "$dir" commit -q -m "ns: plan and acceptance tests for $id"
    fi
  fi
  if [ "$CREATED" -eq 1 ]; then
    ns_stack_setup "$dir" "$profile" >&2 || ns_die "setup failed in $dir"
  fi
  git -C "$dir" push -q -u origin "$branch" >/dev/null 2>&1 || ns_die "could not push $branch"
  if [ "$(lg get "$ledger" '.feature_branch // empty')" != "$branch" ]; then
    lg set "$ledger" ".feature_branch = $(jstr "$branch")"
    lg checkpoint "$ledger"
  fi
  printf '%s\n' "$dir"
}

# conductor_stack_base <id>: print the base branch for the run's PR. With open PRs of other
# runs it merges the top of the stack into the code branch (never a rebase), records
# stacked_on and prints that branch; exit 6 on a conflict (the merge is left in progress), exit 7
# when, after pruning red leaves, the open run PRs form more than one chain or a chain's base is unknown.
conductor_stack_base() {
  [ $# -eq 1 ] || ns_usage "ns-conductor stack-base <id>"
  local base repo prefix fixpat featpat prs top head dir stacked own mout clash others tops closed c own_on own_created clist cands since skipped row msg rem changed chains choices unknown
  load_run "$1"
  budget_guard stack-base || return
  base=$(jq -r '.git.base_branch' <<<"$profile")
  repo=$(jq -r .repo <<<"$project")
  prefix=$(jq -r .prefix <<<"$project")
  fixpat=$(jq -r '.git.fix_branch' <<<"$profile")
  featpat=$(jq -r '.git.feature_branch' <<<"$profile")
  prs=$(ns_stack_open_prs "$repo" "$fixpat" "$featpat" "$prefix" "$(jq -r .path <<<"$project")") || ns_die "could not list the pull requests of $repo"
  own_on=$(lg get "$ledger" '.stacked_on // empty')
  # the run has no PR yet: fall back to the time the run was created
  own_created=$(jq -r --arg me "$id" '[.[] | select(.run == $me) | .createdAt][0] // empty' <<<"$prs")
  [ -n "$own_created" ] || own_created=$(lg get "$ledger" '.created // empty')
  # the closed list (closed and merged PRs) is only needed for a base that is a run branch without an open PR,
  # or for a run stacked on another run; the candidates come from the full list, so this run's own open PR
  # hides a reused head name. One search serves the base-branch check and the closed-base warnings.
  cands=$(ns_stack_closed_candidates "$prs" "$base" "$fixpat" "$featpat" "$prefix")
  clist="[]"
  if [ "$cands" != "[]" ] || { [ -n "$own_on" ] && [ "$own_on" != "$base" ]; }; then
    since=$(ns_stack_closed_since "$prs" "$cands")
    if [ -n "$own_on" ] && [ "$own_on" != "$base" ]; then
      since=$( { [ -z "$since" ] || printf '%s\n' "$since"; [ -z "$own_created" ] || printf '%s\n' "$own_created"; } | sort | head -n 1)
      [ -n "$own_created" ] || since=""
    fi
    clist=$(ns_stack_closed_list "$repo" "$since")
  fi
  # a stack belongs to one base branch: chains that bottom out at another base do not count
  prs=$(ns_stack_on_base "$prs" "$base" "$fixpat" "$featpat" "$prefix" "$repo" "$clist")
  others=$(jq -c --arg me "$id" '[.[] | select(.run != $me)]' <<<"$prs")
  closed=$(ns_stack_closed_heads "$repo" "$prs" "$base" "$clist")
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    printf 'warning: the base of %s (%s) is a PR closed without a merge: use ns stack drop\n' \
      "$(jq -r --arg c "$c" '[.[] | select(.base == $c)][0].run' <<<"$others")" "$c" >&2
  done < <(jq -r '.[].base' <<<"$others" | sort -u | grep -xFf <(printf '%s\n' "$closed") || true)
  if [ -n "$own_on" ] && [ "$own_on" != "$base" ]; then
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      if [ "$(ns_stack_run_id "$fixpat" "$featpat" "$prefix" "$c" || true)" = "$own_on" ] &&
        ! jq -e --arg c "$c" 'any(.[]; .head == $c)' <<<"$prs" >/dev/null; then
        printf 'warning: %s is stacked on %s (%s), a PR closed without a merge: use ns stack drop\n' "$id" "$own_on" "$c" >&2
        break
      fi
    done < <(jq -r --arg t "$own_created" '.[] | select((.merged | not) and .closedAt >= $t) | .headRefName' <<<"$clist")
  fi
  # red base: prune red leaves until nothing changes. A leaf is a PR no remaining run PR is based on; it is
  # pruned when its checks fail (pending and no checks count as not red) and its head is not already merged
  # into the code branch (a PR this run stacked on before stays, and so does everything below it). Only tops
  # decide: a red PR with a remaining PR above it is never pruned.
  dir=$(loop_code_wt)
  rem="$others"
  skipped="[]"
  changed=1
  while [ "$changed" -eq 1 ]; do
    changed=0
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      [ "$(ns_stack_checks_state "$(jq -c .statusCheckRollup <<<"$row")")" = fail ] || continue
      # a PR whose base is unknown may belong to another base branch: it escalates below, it is not skipped
      [ "$(jq -r '.base_unknown // false' <<<"$row")" != true ] || continue
      head=$(jq -r .head <<<"$row")
      if [ -d "$dir" ] && git -C "$dir" fetch -q origin "$head" 2>/dev/null &&
        git -C "$dir" merge-base --is-ancestor "origin/$head" HEAD 2>/dev/null; then
        continue
      fi
      rem=$(jq -c --argjson n "$(jq .number <<<"$row")" 'map(select(.number != $n))' <<<"$rem")
      skipped=$(jq -c --argjson r "$row" '. + [{run: $r.run, number: $r.number}]' <<<"$skipped")
      changed=1
    done < <(jq -c '. as $all | [.[] | . as $p | select(any($all[]; .base == $p.head) | not)] | sort_by(.number) | reverse | .[]' <<<"$rem")
  done
  lg set "$ledger" ".stack_skipped = $skipped"
  [ "$skipped" = "[]" ] || printf 'skipped (checks failing): %s\n' "$(jq -r 'map("#\(.number)") | join(", ")' <<<"$skipped")" >&2
  chains=$(ns_stack_chains "$rem")
  tops=$(jq -c '[.[] | last | .head]' <<<"$chains")
  choices=$(jq -r --arg b "$base" '[$b] + . | if length == 1 then .[0] else (.[:-1] | join(", ")) + " or " + .[-1] end' <<<"$tops")
  unknown=$(jq -r '. as $all | [.[] | select(.base_unknown == true) | . as $p
    | select(any($all[]; .head == $p.base) | not) | "#\(.number) (base \(.base))"] | join(", ")' <<<"$rem")
  if [ -n "$unknown" ]; then
    lg checkpoint "$ledger"
    printf 'cannot tell which base branch the chain of %s belongs to (no open or closed PR found for that base): choose a base by hand (gate 1.5): %s\n' \
      "$unknown" "$choices" >&2
    exit 7
  fi
  if [ "$(jq length <<<"$chains")" -gt 1 ]; then
    lg checkpoint "$ledger"
    printf 'more than one chain of open run PRs on %s (tops: %s): choose a base by hand (gate 1.5): %s\n' \
      "$base" "$(jq -r 'join(", ")' <<<"$tops")" "$choices" >&2
    exit 7
  fi
  top=$(jq -c '.[0][-1] // empty' <<<"$chains")
  if [ "$skipped" != "[]" ]; then
    msg="Stacked on $(if [ -n "$top" ]; then jq -r '"#\(.number)"' <<<"$top"; else printf '%s' "$base"; fi) (checks failing on $(jq -r 'map("#\(.number)") | join(", ")' <<<"$skipped"))"
    printf '%s\n' "$msg" >&2
    lg event "$ledger" stack "$msg"
  fi
  if [ -z "$top" ]; then
    lg set "$ledger" ".stacked_on = $(jstr "$base") | .budget.integrate_from = \$now"
    lg checkpoint "$ledger"
    printf '%s\n' "$base"
    return 0
  fi
  head=$(jq -r .head <<<"$top")
  stacked=$(jq -r .run <<<"$top")
  [ -d "$dir" ] || ns_die "no code worktree for $id: run ns-conductor fix-branch or feature first"
  own=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
  if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
    ns_die "the worktree $dir has uncommitted changes: commit them before stacking"
  fi
  git -C "$dir" fetch -q origin "$head" || ns_die "could not fetch origin $head"
  clash=$(comm -12 <(git -C "$dir" ls-files --others --exclude-standard | sort) \
    <(git -C "$dir" diff --name-only "HEAD...origin/$head" | sort))
  [ -z "$clash" ] || ns_die "untracked files in $dir would be overwritten by merging $head: $(tr '\n' ' ' <<<"$clash")"
  if ! mout=$(git -C "$dir" merge --no-ff -q -m "Merge $head into $own (stacked on $stacked)" "origin/$head" 2>&1); then
    printf '%s\n' "$mout" >&2
    if [ -f "$(git -C "$dir" rev-parse --absolute-git-dir)/MERGE_HEAD" ]; then
      lg set "$ledger" ".stacked_on = $(jstr "$stacked")"
      lg checkpoint "$ledger"
      printf 'conflict merging %s into %s in %s: resolve, commit and rerun the checks\n' "$head" "$own" "$dir" >&2
      exit 6
    fi
    ns_die "could not merge $head into $own in $dir"
  fi
  lg set "$ledger" ".stacked_on = $(jstr "$stacked") | .budget.integrate_from = \$now"
  lg checkpoint "$ledger"
  printf '%s\n' "$head"
}

# loop_phase_wt <phase|feature>
loop_phase_wt() {
  if [ "$1" = feature ]; then
    loop_code_wt
  else
    ns_run_worktree_path "$profile" "$id--$1"
  fi
}

# loop_wt_clean <dir>: succeeds when the worktree has no staged, unstaged or untracked (non-ignored)
# changes; a git failure counts as dirty
loop_wt_clean() {
  local s
  s=$(git -C "$1" status --porcelain) || return 1
  [ -z "$s" ]
}

# loop_checks_key <dir> <canon>: the cache key as compact JSON: the tree of HEAD, the canonical
# target and the sha256 of the profile's checks
loop_checks_key() {
  local tree sha
  tree=$(git -C "$1" rev-parse 'HEAD^{tree}') || ns_die "could not read the tree of $1"
  sha=$(jq -cS '.checks // []' <<<"$profile" | sha256sum | cut -d' ' -f1)
  jq -nc --arg t "$tree" --arg g "$2" --arg s "$sha" '{tree: $t, target: $g, checks_sha: $s}'
}

# loop_checks_same <json file> <key>: succeeds when the stored record has the key's tree, target and
# checks_sha (a missing or unparsable file is no match)
loop_checks_same() {
  jq -e --argjson k "$2" \
    '.tree == $k.tree and .target == $k.target and .checks_sha == $k.checks_sha' "$1" >/dev/null 2>&1
}

# loop_checks_warn <canon> <dir>: warn on stderr when <dir> lacks the run's latest pushed code.
# Always returns 0.
loop_checks_warn() {
  local canon="$1" dir="$2" head br feature phases p ref sha refs=""
  if ! git -C "$dir" fetch -q origin >/dev/null 2>&1; then
    printf 'checks: could not fetch origin; target check skipped\n' >&2
    return 0
  fi
  head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 0
  br=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || br=HEAD
  feature=$(lg get "$ledger" '.feature_branch // empty')
  if [ "$canon" = feature ]; then
    if [ -n "$feature" ]; then
      refs="origin/$feature"
      if [ "$feature" != "$br" ]; then
        printf 'warning: %s is on %s, but the run'"'"'s code branch is %s\n' "$dir" "$br" "$feature" >&2
      fi
    fi
    phases=$(lg get "$ledger" '[(.phases // [])[] | select(.state != "merged") | .id | select(test("^fix-[0-9]+$") | not)] | join(" ")')
    for p in $phases; do
      refs="$refs origin/$(ns_branch_name "$(jq -r '.git.phase_branch' <<<"$profile")" "$id" "$p")"
    done
  else
    refs="origin/$(ns_branch_name "$(jq -r '.git.phase_branch' <<<"$profile")" "$id" "$canon")"
  fi
  for ref in $refs; do
    sha=$(git -C "$dir" rev-parse -q --verify "$ref^{commit}" 2>/dev/null) || continue
    if ! git -C "$dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
      printf 'warning: %s HEAD (%s %s) does not contain %s %s\n' "$dir" "$br" "${head:0:12}" "$ref" "${sha:0:12}" >&2
    fi
  done
  return 0
}

# loop_checks <phase|feature> [--budget] [--force]: run the profile's checks, with the run context
# loaded. --budget marks an explicit `checks` call: the budget check runs first (exit 4 when the
# budget is used up) and the wrong-target warning is printed. Per canonical target a lock
# serializes calls (a waiter replays the result of the call it waited for), and a pass is cached
# by tree (--force reruns). Removes <target>.checks.rc at the start and writes the exit code there
# last (tmp + mv), on every return path, so callers can wait for the file.
loop_checks() {
  local target="$1" budget="" force="" a rc=0 rcf tmp
  shift
  for a in "$@"; do
    case "$a" in
      --budget) budget=1 ;;
      --force) force=1 ;;
    esac
  done
  rcf="$logdir/$target.checks.rc"
  ns_private_dir "$logdir"
  rm -f "$rcf"
  # subshell: an ns_die (exit) in the body must not skip the marker
  (
    local canon who dir lockf lfd start waited=0 clean=0 key json
    canon=$(loop_checks_canon "$target")
    # checks feature is the integrator's own call (after a stack-base merge or conflict)
    if [ -n "$budget" ]; then
      who=""
      [ "$canon" != feature ] || who=integrator
      budget_guard checks "$who" || exit
    fi
    dir=$(loop_phase_wt "$canon")
    [ -d "$dir" ] || ns_die "no worktree for $target at $dir"
    [ -z "$budget" ] || loop_checks_warn "$canon" "$dir"
    lockf="$logdir/$canon.checks.lock"
    json="$logdir/$canon.checks.json"
    start=$(date +%s)
    exec {lfd}>"$lockf"
    if ! flock -n "$lfd"; then
      printf 'checks: another run of %s in %s is in progress; waiting\n' "$canon" "$dir" >&2
      waited=1
      if ! flock -w 3600 "$lfd"; then
        printf 'checks busy: %s in %s is still locked after 3600 s\n' "$canon" "$dir" >&2
        exit 1
      fi
    fi
    ! loop_wt_clean "$dir" || clean=1
    key=$(loop_checks_key "$dir" "$canon")
    if [ -z "$force" ] && [ "$clean" = 1 ] && loop_checks_same "$json" "$key"; then
      if [ "$waited" = 1 ] && jq -e --argjson s "$start" \
        '.finished_epoch >= $s and (.rc != 0 or .cacheable == true)' "$json" >/dev/null 2>&1; then
        loop_checks_show "$json" "checks: result of the concurrent run on tree $(jq -r '.tree' <<<"$key"): $(jq -r 'if .rc == 0 then "PASS" else "FAIL" end' "$json")"
        if jq -e '.rc != 0' "$json" >/dev/null 2>&1; then
          tail -n 40 "$logdir/$canon.checks.log"
        fi
        exit "$(jq -r '.rc' "$json")"
      fi
      if jq -e '.rc == 0 and .cacheable == true' "$json" >/dev/null 2>&1; then
        loop_checks_show "$json" "checks: cached PASS for tree $(jq -r '.tree' <<<"$key") ($canon, $(jq -r '.finished' "$json")); --force reruns"
        exit 0
      fi
    fi
    loop_checks_body "$canon" "$dir" "$key" "$clean" "$lfd"
  ) || rc=$?
  tmp="$rcf.tmp.$$"
  printf '%s\n' "$rc" >"$tmp"
  mv -f "$tmp" "$rcf"
  return "$rc"
}

# loop_checks_show <json file> <header>: print the header, then the stored per-check lines
loop_checks_show() {
  printf '%s\n' "$2"
  jq -r '.results[]?' "$1"
}

# loop_checks_body <canon> <dir> <key> <clean> <lockfd>: run the checks, print their lines, record
# the result in <canon>.checks.json
loop_checks_body() {
  local canon="$1" dir="$2" key="$3" clean="$4" lfd="$5" log res tmp rc=0 cacheable=false tree json
  json="$logdir/$canon.checks.json"
  ns_private_dir "$logdir"
  log="$logdir/$canon.checks.log"
  res=$(mktemp "$logdir/.checks-res.XXXXXX")
  rm -f "$json"
  # {lfd}>&- : the check commands (and any process they leave running) do not inherit the lock
  ns_profile_checks_run "$dir" "$profile" "$log" >"$res" {lfd}>&- || rc=$?
  cat "$res"
  [ "$rc" -eq 0 ] || tail -n 40 "$log"
  tree=$(git -C "$dir" rev-parse 'HEAD^{tree}' 2>/dev/null) || tree=""
  if [ "$clean" = 1 ] && [ "$tree" = "$(jq -r '.tree' <<<"$key")" ] && loop_wt_clean "$dir"; then
    cacheable=true
  fi
  tmp=$(mktemp "$logdir/.checks-json.XXXXXX")
  if jq -n --argjson k "$key" --argjson rc "$rc" --argjson c "$cacheable" \
    --arg head "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" --arg fin "$(ns_now)" \
    --argjson ep "$(date +%s)" --rawfile r "$res" \
    '$k + {rc: $rc, cacheable: $c, head: $head, finished: $fin, finished_epoch: $ep,
      results: ($r | split("\n") | map(select(length > 0)))}' >"$tmp"; then
    mv -f "$tmp" "$json"
  else
    rm -f "$tmp"
  fi
  rm -f "$res"
  return "$rc"
}

conductor_checks() {
  local u="ns-conductor checks <id> <phase|feature> [--force]"
  { [ $# -eq 2 ] || { [ $# -eq 3 ] && [ "$3" = --force ]; }; } || ns_usage "$u"
  [ "$2" = feature ] || valid_phase_id "$2" || ns_usage "$u"
  load_run "$1"
  loop_checks "$2" --budget ${3:+"$3"}
}

conductor_note() {
  local u="ns-conductor note <id> <text> | --file <file>" text n notes
  [ $# -eq 2 ] || [ $# -eq 3 ] || ns_usage "$u"
  load_run "$1"
  if [ "$2" = --file ]; then
    [ $# -eq 3 ] && [ -f "$3" ] || ns_usage "$u"
    text=$(cat "$3")
  else
    [ $# -eq 2 ] || ns_usage "$u"
    text="$2"
  fi
  text=$(printf '%s' "$text" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  [ -n "$text" ] || ns_usage "$u"
  notes="$wt/.nightshift/runs/$id/notes.md"
  mkdir -p "$(dirname "$notes")"
  n=1
  if [ -f "$notes" ]; then
    n=$(grep -c '^[0-9][0-9]*\. ' "$notes" || true)
    n=$((n + 1))
  fi
  printf '%s. %s\n' "$n" "$text" >>"$notes"
  lg event "$ledger" note "note $n: ${text:0:80}"
  lg checkpoint "$ledger"
  printf 'note %s\n' "$n"
}

# loop_has_changes <dir> <feature ref> <phase ref>: exit 0 when the phase branch changes something
# against its merge base with the feature branch, 1 when it changes nothing (equal, behind, or
# commits that cancel out); dies when git fails
loop_has_changes() {
  local rc=0
  git -C "$1" diff --quiet "$2...$3" -- || rc=$?
  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
    *) ns_die "git diff $2...$3 failed in $1" ;;
  esac
}

conductor_report() {
  local u="ns-conductor report <id> <phase> [--rerun]" rerun=false
  if [ $# -eq 3 ] && [ "$3" = --rerun ]; then
    rerun=true
    set -- "$1" "$2"
  fi
  [ $# -eq 2 ] || ns_usage "$u"
  valid_phase_id "$2" || ns_usage "$u"
  local phase="$2" log text rep pbranch want got st hd feature
  load_run "$1"
  log="$logdir/$phase.jsonl"
  if [ "$rerun" = true ]; then
    pbranch=$(ns_branch_name "$(jq -r '.git.phase_branch' <<<"$profile")" "$id" "$phase")
    git -C "$wt" fetch -q origin "$pbranch" 2>/dev/null || true
    want=$(git -C "$wt" rev-parse -q --verify "origin/$pbranch" 2>/dev/null) || want=""
    if [ -z "$want" ]; then
      printf 'origin/%s does not exist\n' "$pbranch"
      return 1
    fi
    # the worker must have pushed something of its own: a phase branch that is the feature
    # branch head, or behind it, holds no work to certify
    feature=$(lg get "$ledger" '.feature_branch // empty')
    [ -n "$feature" ] || ns_die "no feature branch yet"
    git -C "$wt" fetch -q origin "$feature" || ns_die "could not fetch origin $feature"
    git -C "$wt" rev-parse -q --verify "origin/$feature" >/dev/null || ns_die "origin/$feature does not exist"
    if ! loop_has_changes "$wt" "origin/$feature" "origin/$pbranch"; then
      printf 'origin/%s has no changes of its own against origin/%s: nothing of the worker to report; restart the phase\n' "$pbranch" "$feature"
      return 1
    fi
    ns_private_dir "$logdir"
    jq -n -c --arg r "$(printf 'PHASE-REPORT %s status=done head=%s\nregenerated by report --rerun' "$phase" "$want")" \
      '{type: "result", result: $r}' >>"$log"
    lg event "$ledger" report-rerun "$phase $want"
    lg checkpoint "$ledger"
  fi
  if [ ! -f "$log" ]; then
    printf 'no log for %s\n' "$phase"
    return 1
  fi
  text=$(jq -R -c 'fromjson? | select(.type == "result")' "$log" 2>/dev/null | tail -n1 | jq -r '.result // ""') || text=""
  rep=$(printf '%s\n' "$text" | awk '/^PHASE-REPORT /{f=1} f')
  if [ -z "$rep" ]; then
    printf 'no PHASE-REPORT line in the last result of %s\n' "$log"
    return 1
  fi
  printf '%s\n' "$rep"
  st=$(printf '%s\n' "$rep" | head -n1 | sed -n 's/.* status=\([^ ]*\).*/\1/p')
  hd=$(printf '%s\n' "$rep" | head -n1 | sed -n 's/.* head=\([^ ]*\).*/\1/p')
  if [ "$st" != "done" ]; then
    printf 'report says status=%s, not done\n' "${st:-unknown}"
    return 1
  fi
  pbranch=$(ns_branch_name "$(jq -r '.git.phase_branch' <<<"$profile")" "$id" "$phase")
  git -C "$wt" fetch -q origin "$pbranch" 2>/dev/null || true
  want=$(git -C "$wt" rev-parse -q --verify "origin/$pbranch" 2>/dev/null) || want=""
  if [ -z "$want" ]; then
    printf 'origin/%s does not exist\n' "$pbranch"
    return 1
  fi
  got="$hd"
  if [ -z "$got" ] || [ "${#got}" -lt 7 ] || [[ $want != "$got"* ]]; then
    printf 'head mismatch: report says %s, origin/%s is %s\n' "${got:-none}" "$pbranch" "$want"
    return 1
  fi
  return 0
}

# loop_review_refused <message>: print why review-round recorded nothing, and what to do
loop_review_refused() {
  printf '%s\n' "$1" >&2
  printf 'review-round recorded nothing: run the review again; never edit the review file\n' >&2
}

conductor_review_round() {
  local u="ns-conductor review-round <id> <phase> <approve|changes>"
  [ $# -eq 3 ] || ns_usage "$u"
  valid_phase_id "$2" || ns_usage "$u"
  case "$3" in
    approve | changes) ;;
    *) ns_usage "$u" ;;
  esac
  local phase="$2" verdict="$3" tier max n pbranch head rf rel line fv fh hj
  load_run "$1"
  budget_guard review-round || return
  tier=$(loop_tier)
  max=$(jq -r --arg t "$tier" '.budgets[$t].review_rounds // 3' <<<"$profile")
  n=$(lg get "$ledger" "[.phases[] | select(.id == $(jstr "$phase")) | .review_rounds] | (.[0] // 0)")
  n=$((n + 1))
  # the review file of this round must back the verdict: an approval needs
  # RUN/review-<phase>-<n>.md ending with "REVIEW verdict=approve head=<sha>", <sha> being the
  # current phase head; a verdict line that says the other verdict refuses either argument
  # the reviewed branch: the phase branch, or for T0/T1 the run's fix branch (one code branch)
  case "$tier" in
    T0 | T1) pbranch=$(lg get "$ledger" '.feature_branch // empty') ;;
    *) pbranch=$(ns_branch_name "$(jq -r '.git.phase_branch' <<<"$profile")" "$id" "$phase") ;;
  esac
  head=""
  if [ -n "$pbranch" ]; then
    if git -C "$wt" fetch -q origin "$pbranch" 2>/dev/null; then
      head=$(git -C "$wt" rev-parse -q --verify "origin/$pbranch" 2>/dev/null) || head=""
    elif [ "$verdict" = approve ]; then
      # never compare an approval with a stale remote-tracking ref
      ns_die "could not fetch origin $pbranch"
    fi
  fi
  rf="$wt/.nightshift/runs/$id/review-$phase-$n.md"
  rel="RUN/review-$phase-$n.md"
  line="" fv="" fh="" fhbad=0
  if [ -f "$rf" ]; then
    line=$(awk '{ sub(/\r$/, "") } NF { l = $0 } END { sub(/[ \t]+$/, "", l); print l }' "$rf")
    # the verdict first, then the head on its own, so a malformed head gets its own message
    if [[ $line =~ ^REVIEW\ verdict=(approve|changes)(\ head=(.*))?$ ]]; then
      fv="${BASH_REMATCH[1]}"
      fh="${BASH_REMATCH[3]}"
      if [ -n "${BASH_REMATCH[2]}" ] && ! [[ $fh =~ ^[0-9a-f]{7,64}$ ]]; then
        fhbad=1
      fi
    fi
  fi
  if [ "$verdict" = approve ] && [ ! -f "$rf" ]; then
    loop_review_refused "$rel does not exist: an approval needs the review file of round $n"
    return 9
  fi
  if [ "$verdict" = approve ] && [ -z "$fv" ]; then
    loop_review_refused "$rel has no REVIEW verdict line: an approval needs one"
    return 9
  fi
  if [ -n "$fv" ] && [ "$fv" != "$verdict" ]; then
    loop_review_refused "$rel ends with '$line', not verdict $verdict"
    return 9
  fi
  if [ "$verdict" = approve ] && [ "$fhbad" = 1 ]; then
    loop_review_refused "$rel: head='${fh:0:20}' is not 7 to 64 lowercase hex"
    return 9
  fi
  if [ "$verdict" = approve ]; then
    if [ -z "$fh" ]; then
      loop_review_refused "$rel has no head=<sha> on its verdict line: an approval names the head it reviewed"
      return 9
    fi
    if [ -z "$head" ] || [[ $head != "$fh"* ]]; then
      loop_review_refused "$rel approved head=${fh:0:12}, but origin/$pbranch is ${head:-missing}: the review is of another head"
      return 9
    fi
  fi
  hj=null
  [ -z "$head" ] || hj=$(jstr "$head")
  phase_update "$phase" ".review_rounds = $n | .review_verdict = $(jstr "$verdict") | .reviewed_head = $hj"
  lg event "$ledger" review "$phase round $n $verdict"
  lg checkpoint "$ledger"
  # The cap counts reviews that ran: an approval always proceeds, and changes on the last
  # allowed round escalate instead of starting a review the budget does not cover.
  if [ "$verdict" = changes ] && [ "$n" -ge "$max" ]; then
    printf '%s: review round %s asked for changes and reaches the cap of %s for %s\n' "$phase" "$n" "$max" "$tier"
    return 7
  fi
  printf '%s: review round %s of %s\n' "$phase" "$n" "$max"
}

conductor_merge() {
  [ $# -eq 2 ] || ns_usage "ns-conductor merge <id> <phase>"
  valid_phase_id "$2" || ns_usage "ns-conductor merge <id> <phase>"
  local phase="$2" fw trailer pbranch feature title pre pwt mlog head verdict rhead pj
  load_run "$1"
  fw=$(loop_code_wt)
  [ -d "$fw" ] || ns_die "no feature worktree at $fw"
  trailer=$(jq -r '.git.phase_trailer' <<<"$profile")
  pbranch=$(ns_branch_name "$(jq -r '.git.phase_branch' <<<"$profile")" "$id" "$phase")
  feature=$(lg get "$ledger" '.feature_branch // empty')
  [ -n "$feature" ] || ns_die "no feature branch yet"
  mlog=$(git -C "$fw" log --format=%B) || ns_die "git log failed in $fw"
  if grep -qxF "$trailer: $phase" <<<"$mlog"; then
    printf 'already merged\n'
    phase_update "$phase" '.state = "merged"'
    return 0
  fi
  git -C "$fw" fetch -q origin || ns_die "could not fetch origin"
  head=$(git -C "$fw" rev-parse -q --verify "origin/$pbranch" 2>/dev/null) || head=""
  if [ -z "$head" ]; then
    printf 'origin/%s does not exist\n' "$pbranch"
    return 1
  fi
  if ! loop_has_changes "$fw" "origin/$feature" "origin/$pbranch"; then
    printf 'origin/%s has no changes of its own against origin/%s: nothing to merge\n' "$pbranch" "$feature"
    return 1
  fi
  # only a review round that approved exactly the current phase head lets the phase in
  pj=$(jstr "$phase")
  verdict=$(lg get "$ledger" "[.phases[] | select(.id == $pj) | .review_verdict] | (.[0] // \"none\")")
  rhead=$(lg get "$ledger" "[.phases[] | select(.id == $pj) | .reviewed_head] | (.[0] // \"\")")
  if [ -z "$head" ] || [ "$verdict" != approve ] || [ "$rhead" != "$head" ]; then
    printf 'no approved review of origin/%s at %s (last review: %s of %s): run a review round on this head first\n' \
      "$pbranch" "${head:0:12}" "$verdict" "${rhead:0:12}"
    return 8
  fi
  title=$(lg get "$ledger" "[.phases[] | select(.id == $(jstr "$phase")) | .title] | (.[0] // $(jstr "$phase"))")
  pre=$(git -C "$fw" rev-parse HEAD)
  if ! git -C "$fw" merge -q --no-ff "origin/$pbranch" -m "Merge $id $phase: $title" -m "$trailer: $phase" >/dev/null 2>&1; then
    git -C "$fw" merge --abort >/dev/null 2>&1 || true
    git -C "$fw" reset -q --hard "$pre"
    printf 'conflict\n'
    return 1
  fi
  if ! loop_checks feature; then
    git -C "$fw" reset -q --hard "$pre"
    return 1
  fi
  git -C "$fw" push -q origin "HEAD:refs/heads/$feature" >/dev/null 2>&1 || ns_die "could not push $feature"
  pwt=$(ns_run_worktree_path "$profile" "$id--$phase")
  phase_update "$phase" '.state = "merged"'
  lg event "$ledger" merge "$phase merged into $feature"
  lg checkpoint "$ledger"
  if [ -d "$pwt" ]; then
    git -C "$fw" worktree remove --force "$pwt" >/dev/null 2>&1 || ns_warn "could not remove $pwt"
  fi
  printf 'merged %s\n' "$phase"
}

conductor_gate() {
  [ $# -ge 3 ] || ns_usage "ns-conductor gate <id> <1|1.5|2> <file>[:<name>]..."
  local gate="$2"
  case "$gate" in
    1 | 1.5 | 2) ;;
    *) ns_usage "ns-conductor gate <id> <1|1.5|2> <file>[:<name>]..." ;;
  esac
  load_run "$1"
  shift 2
  # gate 1.5: the question goes into the event note, so each escalation keeps its cause (#118)
  local note="gate $gate: waiting for the owner" q=""
  if [ "$gate" = 1.5 ] && [ -f "$wt/.nightshift/runs/$id/escalation.md" ]; then
    q=$(ns_escalation_question "$wt/.nightshift/runs/$id/escalation.md") || q=""
  fi
  [ -z "$q" ] || note="$note: $q"
  lg state "$ledger" waiting --gate "$gate"
  lg event "$ledger" gate "$note"
  lg checkpoint "$ledger" --push
  "$NS_HOME/bin/ns" publish "$id" "$@"
}

conductor_finish() {
  [ $# -eq 3 ] && [ "$2" = --pr ] || ns_usage "ns-conductor finish <id> --pr <url>"
  local url="$3" tier handoff
  load_run "$1"
  tier=$(loop_tier)
  lg set "$ledger" ".pr = $(jstr "$url") | .step = \"done\""
  case "$tier" in
    T2 | T3) lg state "$ledger" "done" --gate 2 --note "pull request $url" ;;
    *) lg state "$ledger" "done" --note "pull request $url" ;;
  esac
  lg event "$ledger" finish "run finished: $url"
  # the run report is best effort: writing or publishing it never fails the run. The
  # handoff report of a T2/T3 run is not: the owner needs it at gate 2 (#118)
  local report=false hand=false
  if "$NS_HOME/bin/ns" report "$id" >/dev/null; then
    report=true
  else
    ns_warn "could not write the run report for $id"
  fi
  handoff="$wt/.nightshift/runs/$id/handoff.html"
  case "$tier" in
    T2 | T3) [ ! -f "$handoff" ] || hand=true ;;
  esac
  lg checkpoint "$ledger" --push
  local -a docs=()
  [ "$hand" = false ] || docs+=("RUN/handoff.html")
  [ "$report" = false ] || docs+=("RUN/run-report.md")
  # one publish (one notification) when both are fine; else each on its own
  if [ "${#docs[@]}" -gt 0 ] && ! "$NS_HOME/bin/ns" publish "$id" "${docs[@]}"; then
    if [ "$report" = true ] && { [ "$hand" = false ] || ! "$NS_HOME/bin/ns" publish "$id" RUN/run-report.md; }; then
      ns_warn "could not publish RUN/run-report.md"
    fi
    if [ "$hand" = true ] && ! "$NS_HOME/bin/ns" publish "$id" RUN/handoff.html; then
      ns_die "could not publish the handoff report: fix RUN/handoff.html, then ns publish $id RUN/handoff.html"
    fi
  fi
  printf 'finished %s: %s\n' "$id" "$url"
}

conductor_pause() {
  [ $# -eq 1 ] || ns_usage "ns-conductor pause <id>"
  load_run "$1"
  lg set "$ledger" '.budget.paused = true'
  lg event "$ledger" usage-pause "budget paused"
  lg checkpoint "$ledger"
  printf 'paused %s\n' "$id"
}

conductor_unpause() {
  [ $# -eq 1 ] || ns_usage "ns-conductor unpause <id>"
  load_run "$1"
  lg set "$ledger" '.budget.paused = false | .budget.paused_until = null'
  lg event "$ledger" usage-resume "budget resumed"
  lg checkpoint "$ledger"
  printf 'unpaused %s\n' "$id"
}

# conductor_loop_dispatch <subcommand> [args]: returns 64 for an unknown subcommand
conductor_loop_dispatch() {
  local sub="$1"
  shift
  case "$sub" in
    fix-branch) conductor_fix_branch "$@" ;;
    feature) conductor_feature "$@" ;;
    stack-base) conductor_stack_base "$@" ;;
    checks) conductor_checks "$@" ;;
    report) conductor_report "$@" ;;
    note) conductor_note "$@" ;;
    review-round) conductor_review_round "$@" ;;
    merge) conductor_merge "$@" ;;
    gate) conductor_gate "$@" ;;
    finish) conductor_finish "$@" ;;
    pause) conductor_pause "$@" ;;
    unpause) conductor_unpause "$@" ;;
    *) return 64 ;;
  esac
}

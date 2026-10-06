# shellcheck shell=bash
# shellcheck disable=SC2154  # the run context variables are set by load_run in bin/ns-conductor
# ns-conductor subcommands of the phase loop: branches, checks, report, review rounds, merge,
# gates, finish, pause. Sourced by bin/ns-conductor, which provides load_run, lg, jstr,
# phase_update and the run context (id, run, wt, ledger, profile, plan_doc, logdir).

conductor_loop_usage() {
  printf '  fix-branch    <id>\n'
  printf '  feature       <id>\n'
  printf '  stack-base    <id>\n'
  printf '  checks        <id> <phase|feature>\n'
  printf '  report        <id> <phase> [--rerun]\n'
  printf '  note          <id> <text> | --file <file>\n'
  printf '  review-round  <id> <phase>\n'
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

# loop_code_wt: worktree of the code branch (<id>--fix for T0/T1, <id>--feature otherwise)
loop_code_wt() {
  case "$(loop_tier)" in
    T0 | T1) ns_run_worktree_path "$profile" "$id--fix" ;;
    *) ns_run_worktree_path "$profile" "$id--feature" ;;
  esac
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
# when the open run PRs form more than one chain.
conductor_stack_base() {
  [ $# -eq 1 ] || ns_usage "ns-conductor stack-base <id>"
  local base repo prefix fixpat featpat prs top head dir stacked own mout clash others tops closed c own_on own_created
  load_run "$1"
  base=$(jq -r '.git.base_branch' <<<"$profile")
  repo=$(jq -r .repo <<<"$project")
  prefix=$(jq -r .prefix <<<"$project")
  fixpat=$(jq -r '.git.fix_branch' <<<"$profile")
  featpat=$(jq -r '.git.feature_branch' <<<"$profile")
  prs=$(ns_stack_open_prs "$repo" "$fixpat" "$featpat" "$prefix" "$(jq -r .path <<<"$project")") || ns_die "could not list the pull requests of $repo"
  others=$(jq -c --arg me "$id" '[.[] | select(.run != $me)]' <<<"$prs")
  closed=$(ns_stack_closed_heads "$repo" "$others" "$base")
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    printf 'warning: the base of %s (%s) is a PR closed without a merge: use ns stack drop\n' \
      "$(jq -r --arg c "$c" '[.[] | select(.base == $c)][0].run' <<<"$others")" "$c" >&2
  done < <(jq -r '.[].base' <<<"$others" | sort -u | grep -xFf <(printf '%s\n' "$closed") || true)
  own_on=$(lg get "$ledger" '.stacked_on // empty')
  if [ -n "$own_on" ] && [ "$own_on" != "$base" ]; then
    own_created=$(jq -r --arg me "$id" '[.[] | select(.run == $me) | .createdAt][0] // ""' <<<"$prs")
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      if [ "$(ns_stack_run_id "$fixpat" "$featpat" "$prefix" "$c" || true)" = "$own_on" ] &&
        ! jq -e --arg c "$c" 'any(.[]; .head == $c)' <<<"$prs" >/dev/null; then
        printf 'warning: %s is stacked on %s (%s), a PR closed without a merge: use ns stack drop\n' "$id" "$own_on" "$c" >&2
        break
      fi
    done < <(ns_stack_closed_list "$repo" | jq -r --arg t "$own_created" '.[] | select(.closedAt >= $t) | .headRefName')
  fi
  if [ "$(ns_stack_chains "$others" | jq length)" -gt 1 ]; then
    tops=$(ns_stack_chains "$others" | jq -r '[.[] | last | .head] | join(", ")')
    printf 'more than one chain of open run PRs (tops: %s): choose a base by hand (gate 1.5)\n' "$tops" >&2
    exit 7
  fi
  top=$(jq -c 'last // empty' <<<"$others")
  if [ -z "$top" ]; then
    lg set "$ledger" ".stacked_on = $(jstr "$base")"
    lg checkpoint "$ledger"
    printf '%s\n' "$base"
    return 0
  fi
  head=$(jq -r .head <<<"$top")
  stacked=$(jq -r .run <<<"$top")
  dir=$(loop_code_wt)
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
  lg set "$ledger" ".stacked_on = $(jstr "$stacked")"
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

# loop_checks <phase|feature>: run the profile's checks, with the run context loaded.
# Removes <target>.checks.rc at the start and writes the exit code there last
# (tmp + mv), on every return path, so callers can wait for the file.
loop_checks() {
  local target="$1" rc=0 rcf tmp
  rcf="$logdir/$target.checks.rc"
  mkdir -p "$logdir"
  rm -f "$rcf"
  # subshell: an ns_die (exit) in the body must not skip the marker
  ( loop_checks_body "$target" ) || rc=$?
  tmp="$rcf.tmp.$$"
  printf '%s\n' "$rc" >"$tmp"
  mv -f "$tmp" "$rcf"
  return "$rc"
}

loop_checks_body() {
  local target="$1" dir log n stack name cmd failed=0 total crc
  dir=$(loop_phase_wt "$target")
  [ -d "$dir" ] || ns_die "no worktree for $target at $dir"
  total=$(jq '(.checks // []) | length' <<<"$profile")
  if [ "$total" -eq 0 ]; then
    printf 'no checks configured\n'
    return 0
  fi
  mkdir -p "$logdir"
  log="$logdir/$target.checks.log"
  : >"$log"
  n=0
  while [ "$n" -lt "$total" ]; do
    stack=$(jq -r ".checks[$n].stack" <<<"$profile")
    name=$(jq -r ".checks[$n].name" <<<"$profile")
    cmd=$(jq -r ".checks[$n].cmd" <<<"$profile")
    printf '== %s %s: %s\n' "$stack" "$name" "$cmd" >>"$log"
    crc=0
    (cd "$dir" && env -i HOME="${HOME:-}" PATH="$PATH" LANG="${LANG:-C.UTF-8}" TERM="${TERM:-dumb}" \
      TMPDIR="${TMPDIR:-/tmp}" bash -c "$cmd") >>"$log" 2>&1 </dev/null || crc=$?
    if [ "$crc" -eq 0 ]; then
      printf 'PASS %s %s\n' "$stack" "$name"
    elif [ "$crc" -eq 5 ] && { { [ "$stack" = python ] && [ "$name" = test ]; } || [[ $cmd == *pytest* ]]; }; then
      printf 'SKIP %s %s\n' "$stack" "$name"
    else
      printf 'FAIL %s %s\n' "$stack" "$name"
      failed=1
    fi
    n=$((n + 1))
  done
  if [ "$failed" -eq 1 ]; then
    tail -n 40 "$log"
    return 1
  fi
  return 0
}

conductor_checks() {
  [ $# -eq 2 ] || ns_usage "ns-conductor checks <id> <phase|feature>"
  [ "$2" = feature ] || valid_phase_id "$2" || ns_usage "ns-conductor checks <id> <phase|feature>"
  load_run "$1"
  loop_checks "$2"
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

conductor_report() {
  local u="ns-conductor report <id> <phase> [--rerun]" rerun=false
  if [ $# -eq 3 ] && [ "$3" = --rerun ]; then
    rerun=true
    set -- "$1" "$2"
  fi
  [ $# -eq 2 ] || ns_usage "$u"
  valid_phase_id "$2" || ns_usage "$u"
  local phase="$2" log text rep pbranch want got st hd
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
    mkdir -p "$logdir"
    jq -n -c --arg r "$(printf 'PHASE-REPORT %s status=done head=%s\nregenerated by report --rerun' "$phase" "$want")" \
      '{type: "result", result: $r}' >>"$log"
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

conductor_review_round() {
  [ $# -eq 2 ] || ns_usage "ns-conductor review-round <id> <phase>"
  valid_phase_id "$2" || ns_usage "ns-conductor review-round <id> <phase>"
  local phase="$2" tier max n
  load_run "$1"
  tier=$(loop_tier)
  max=$(jq -r --arg t "$tier" '.budgets[$t].review_rounds // 3' <<<"$profile")
  phase_update "$phase" '.review_rounds += 1'
  n=$(lg get "$ledger" "[.phases[] | select(.id == $(jstr "$phase")) | .review_rounds] | .[0]")
  lg event "$ledger" review "$phase round $n"
  lg checkpoint "$ledger"
  if [ "$n" -gt "$max" ]; then
    printf '%s: review round %s exceeds the %s allowed for %s\n' "$phase" "$n" "$max" "$tier"
    return 7
  fi
  printf '%s: review round %s of %s\n' "$phase" "$n" "$max"
}

conductor_merge() {
  [ $# -eq 2 ] || ns_usage "ns-conductor merge <id> <phase>"
  valid_phase_id "$2" || ns_usage "ns-conductor merge <id> <phase>"
  local phase="$2" fw trailer pbranch feature title pre pwt mlog
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
  lg state "$ledger" waiting --gate "$gate"
  lg event "$ledger" gate "gate $gate: waiting for the owner"
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
  # the run report is best effort: a failure here never fails the run
  local -a docs=()
  if "$NS_HOME/bin/ns" report "$id" >/dev/null; then
    docs+=("RUN/run-report.md")
  else
    ns_warn "could not write the run report for $id"
  fi
  handoff="$wt/.nightshift/runs/$id/handoff.html"
  case "$tier" in
    T2 | T3) [ ! -f "$handoff" ] || docs=("RUN/handoff.html" "${docs[@]}") ;;
  esac
  lg checkpoint "$ledger" --push
  if [ "${#docs[@]}" -gt 0 ]; then
    "$NS_HOME/bin/ns" publish "$id" "${docs[@]}" || ns_warn "could not publish ${docs[*]}"
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
  lg set "$ledger" '.budget.paused = false'
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

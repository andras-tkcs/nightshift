# shellcheck shell=bash
# Stacked run PRs: find the open PRs of Nightshift runs and order them as one line
# main <- a <- b. Functions only; source this file. Needs common.sh.

# ns_stack_pattern_re <pattern> <prefix>: print the regex for a branch-name pattern;
# {slug} is a run id of the prefix, {n} the run number
ns_stack_pattern_re() {
  local pat="$1" prefix="$2" re
  re=$(printf '%s' "$pat" | sed 's/[][\.*^$+?()|]/\\&/g')
  re=${re//\{slug\}/($prefix-[0-9a-z]+)}
  re=${re//\{n\}/([0-9]+)}
  printf '^%s$\n' "$re"
}

# ns_stack_run_id <fix pattern> <feature pattern> <prefix> <branch>: print the run id a code
# branch belongs to; return 1 when it is not a run branch of the prefix
ns_stack_run_id() {
  local fixpat="$1" featpat="$2" prefix="$3" branch="$4" pat re
  for pat in "$fixpat" "$featpat"; do
    re=$(ns_stack_pattern_re "$pat" "$prefix")
    if [[ $branch =~ $re ]]; then
      if [[ $pat == *'{slug}'* ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
      else
        printf '%s-%s\n' "$prefix" "${BASH_REMATCH[1]}"
      fi
      return 0
    fi
  done
  return 1
}

# ns_stack_open_prs <repo> <fix pattern> <feature pattern> <prefix> <clone path>: JSON array of
# the open run PRs, bottom to top (a PR counts only when plan/<run id> exists on origin): {run, number, head, base, createdAt, reviewDecision, statusCheckRollup}.
# Depth is the number of PRs below it (following baseRefName); ties go by creation time.
ns_stack_open_prs() {
  local repo="$1" fixpat="$2" featpat="$3" prefix="$4" path="${5:-}" prs rows="[]" row head rid plans
  plans=$(git -C "$path" ls-remote --heads origin 'plan/*' 2>/dev/null) || return 1
  plans=$(awk '{sub("refs/heads/", "", $2); print $2}' <<<"$plans")
  prs=$(gh pr list --repo "$repo" --state open --limit 100 \
    --json number,headRefName,baseRefName,createdAt,reviewDecision,statusCheckRollup) || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    head=$(jq -r .headRefName <<<"$row")
    rid=$(ns_stack_run_id "$fixpat" "$featpat" "$prefix" "$head") || continue
    grep -qxF "plan/$rid" <<<"$plans" || continue
    rows=$(jq -c --argjson r "$row" --arg rid "$rid" \
      '. + [{run: $rid, number: $r.number, head: $r.headRefName, base: $r.baseRefName,
        createdAt: $r.createdAt, reviewDecision: ($r.reviewDecision // ""),
        statusCheckRollup: ($r.statusCheckRollup // [])}]' <<<"$rows")
  done < <(jq -c '.[]' <<<"$prs")
  jq -c '. as $all | length as $max
    | def depth($p; $n): if $n <= 0 then 0
        else ([$all[] | select(.head == $p.base)] | first) as $b
          | if $b == null then 0 else 1 + depth($b; $n - 1) end end;
    map(. + {depth: depth(.; $max)}) | sort_by([.depth, .createdAt]) | map(del(.depth))' <<<"$rows"
}

# ns_stack_on_base <open prs json> <base branch> <fix pattern> <feature pattern> <prefix>: keep the run PRs
# whose chain bottoms out at the base branch: a stack belongs to one base branch. A chain whose bottom PR
# targets a run branch without an open PR (its PR was closed or merged) is kept, so a closed base is still
# reported; PRs whose bases form a cycle have no bottom and are kept. Chains on another base are dropped.
ns_stack_on_base() {
  local prs="$1" basebr="$2" fixpat="$3" featpat="$4" prefix="$5" b ok="[]"
  prs=$(jq -c '. as $all
    | def up($p): [$all[] | select(.head == $p.base)] | first;
      def bottom($p; $seen): up($p) as $b
        | if $b == null then $p.base elif any($seen[]; . == $b.head) then null else bottom($b; $seen + [$b.head]) end;
    map(. + {bottom: bottom(.; [.head])})' <<<"$prs")
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if ns_stack_run_id "$fixpat" "$featpat" "$prefix" "$b" >/dev/null; then ok=$(jq -c --arg b "$b" '. + [$b]' <<<"$ok"); fi
  done < <(jq -r --arg base "$basebr" '[.[].bottom | select(. != null and . != $base)] | unique | .[]' <<<"$prs")
  jq -c --arg base "$basebr" --argjson ok "$ok" \
    'map(select(.bottom == null or .bottom == $base or (.bottom as $x | any($ok[]; . == $x))) | del(.bottom))' <<<"$prs"
}

# ns_stack_checks_state <statusCheckRollup json>: none | pending | fail | pass
ns_stack_checks_state() {
  jq -r 'if length == 0 then "none"
    elif any(.[]; ((.conclusion // .state // "") | ascii_upcase) as $c
      | $c == "FAILURE" or $c == "ERROR" or $c == "TIMED_OUT" or $c == "CANCELLED" or $c == "STARTUP_FAILURE" or $c == "ACTION_REQUIRED") then "fail"
    elif any(.[]; ((.status // "COMPLETED") | ascii_upcase) != "COMPLETED"
      or ((.state // "") | ascii_upcase) == "PENDING") then "pending"
    else "pass" end' <<<"$1"
}

# ns_stack_chains <open prs json>: JSON array of chains, each an array of PRs bottom to top.
# One chain per leaf (a PR no other run PR is based on); a lower PR shared by a fork is in each chain.
ns_stack_chains() {
  local out
  out=$(jq -c '. as $all | length as $max
    | def path($p; $n): if $n <= 0 then [$p]
        else ([$all[] | select(.head == $p.base)] | first) as $b
          | if $b == null then [$p] else path($b; $n - 1) + [$p] end end;
    ([.[] as $p | select(any($all[]; .base == $p.head) | not) | path($p; $max)]) as $c
    | if ($c | length) == 0 and ($all | length) > 0 then [$all[] | [.]] else $c end' <<<"$1")
  if jq -e 'length > 0 and (. as $all | all(.[]; . as $p | any($all[]; .base == $p.head)))' <<<"$1" >/dev/null; then
    printf 'warning: the bases of the open run PRs form a cycle: listing each PR on its own\n' >&2
  fi
  printf '%s\n' "$out"
}

# ns_stack_closed_list <repo>: JSON array of the PRs closed without a merge (number, headRefName, closedAt)
ns_stack_closed_list() {
  gh pr list --repo "$1" --state closed --limit 100 --json number,headRefName,state,mergedAt,closedAt 2>/dev/null \
    | jq -c '[.[] | select((.state // "") == "CLOSED" and .mergedAt == null)
        | {number, headRefName, closedAt: (.closedAt // "9999")}]' 2>/dev/null || printf '[]\n'
}

# ns_stack_closed_heads <repo> <open prs json> [base branch] [closed list json]: print the bases of the
# open run PRs that are a PR closed without a merge. A base counts when it is not the base branch, no open
# PR has that head (a reused name) and a closed unmerged PR has that head and was closed at or after the
# dependent PR was created. The closed list is fetched when not given.
ns_stack_closed_heads() {
  local repo="$1" prs="$2" basebr="${3:-}" cl="${4:-}" cands
  cands=$(jq -c --arg b "$basebr" '. as $all | [.[] | .base | select(. != $b)
    | select(. as $x | any($all[]; .head == $x) | not)] | unique' <<<"$prs" 2>/dev/null || printf '[]')
  [ "$cands" != '[]' ] || return 0
  [ -n "$cl" ] || cl=$(ns_stack_closed_list "$repo")
  jq -r --argjson prs "$prs" --argjson cands "$cands" '. as $cl
    | $prs | [.[] | . as $p | select(any($cands[]; . == $p.base))
        | select(any($cl[]; .headRefName == $p.base and .closedAt >= $p.createdAt)) | .base]
    | unique | .[]' <<<"$cl" 2>/dev/null || true
}

# ns_stack_gate <pr json> <live json>: print why a PR cannot be merged (one line, empty when it can).
# Review decision, checks, mergeability and state come from the live `gh pr view`; the PR list row is the fallback.
ns_stack_gate() {
  local row="$1" live="$2" rev checks mergeable state
  rev=$(jq -r --argjson r "$row" 'if has("reviewDecision") then .reviewDecision else $r.reviewDecision end // ""' <<<"$live")
  checks=$(ns_stack_checks_state "$(jq -c --argjson r "$row" 'if has("statusCheckRollup") then .statusCheckRollup else $r.statusCheckRollup end // []' <<<"$live")")
  mergeable=$(jq -r '.mergeable // ""' <<<"$live")
  state=$(jq -r '.state // "OPEN"' <<<"$live")
  if [ "$state" != OPEN ]; then
    printf 'is %s, not open\n' "$state"
  elif [ "$rev" != APPROVED ]; then
    printf 'is not approved (review: %s)\n' "${rev:--}"
  elif [ "$checks" = fail ] || [ "$checks" = pending ]; then
    printf 'has checks that are not green (%s)\n' "$checks"
  elif [ "$mergeable" = CONFLICTING ]; then
    printf 'has merge conflicts\n'
  fi
}

# ns_stack_find_project <selector>: print the registered project JSON for a prefix, name or owner/repo
ns_stack_find_project() {
  local out
  out=$(ns_projects_json | jq -c --arg s "$1" '[.[] | select(.prefix == $s or .name == $s or .repo == $s)] | first // empty')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# ns_stack_project_base <project json>: print the profile's base branch of the project
ns_stack_project_base() {
  local p="$1" prof
  prof=$(ns_profile_json "$(jq -r .path <<<"$p")" "$(jq -r .prefix <<<"$p")" "$(jq -r '.branch // ""' <<<"$p")" 2>/dev/null) ||
    [ $? -eq 3 ] || return 1
  jq -r '.git.base_branch' <<<"$prof"
}

# ns_stack_project_prs <project json>: print the open run PRs of the project whose chain is on the profile's
# base branch (JSON array, bottom to top)
ns_stack_project_prs() {
  local p="$1" prof path prefix branch fixpat featpat prs
  path=$(jq -r .path <<<"$p")
  prefix=$(jq -r .prefix <<<"$p")
  branch=$(jq -r '.branch // ""' <<<"$p")
  prof=$(ns_profile_json "$path" "$prefix" "$branch" 2>/dev/null) || [ $? -eq 3 ] || return 1
  fixpat=$(jq -r '.git.fix_branch' <<<"$prof")
  featpat=$(jq -r '.git.feature_branch' <<<"$prof")
  prs=$(ns_stack_open_prs "$(jq -r .repo <<<"$p")" "$fixpat" "$featpat" "$prefix" "$path") || return 1
  ns_stack_on_base "$prs" "$(jq -r '.git.base_branch' <<<"$prof")" "$fixpat" "$featpat" "$prefix"
}

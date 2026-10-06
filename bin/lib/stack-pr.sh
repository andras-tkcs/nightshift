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

# ns_stack_gh_open <repo>: JSON array of every open PR of the repo, all pages (GraphQL, 100 per page), in the
# shape of `gh pr list --json number,headRefName,baseRefName,createdAt,reviewDecision,statusCheckRollup`.
# The rollup holds the check runs and status contexts of the head commit.
ns_stack_gh_open() {
  local out
  # shellcheck disable=SC2016
  out=$(gh api graphql --paginate -f owner="${1%%/*}" -f name="${1#*/}" -f query='query OpenRunPRs($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) { pullRequests(states: OPEN, first: 100, after: $endCursor) {
    pageInfo { hasNextPage endCursor }
    nodes { number headRefName baseRefName createdAt reviewDecision
      commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
        __typename ... on CheckRun { name status conclusion } ... on StatusContext { context state } } } } } } } } } } }' \
    --jq '.data.repository.pullRequests.nodes[] | {number, headRefName, baseRefName, createdAt,
      reviewDecision: (.reviewDecision // ""),
      statusCheckRollup: [.commits.nodes[]?.commit.statusCheckRollup.contexts.nodes[]?]}') || return 1
  jq -sc . <<<"$out"
}

# ns_stack_open_prs <repo> <fix pattern> <feature pattern> <prefix> <clone path>: JSON array of
# the open run PRs, bottom to top (a PR counts only when plan/<run id> exists on origin): {run, number, head, base, createdAt, reviewDecision, statusCheckRollup}.
# Depth is the number of PRs below it (following baseRefName); ties go by creation time.
ns_stack_open_prs() {
  local repo="$1" fixpat="$2" featpat="$3" prefix="$4" path="${5:-}" prs rows="[]" row head rid plans
  plans=$(git -C "$path" ls-remote --heads origin 'plan/*' 2>/dev/null) || return 1
  plans=$(awk '{sub("refs/heads/", "", $2); print $2}' <<<"$plans")
  prs=$(ns_stack_gh_open "$repo") || return 1
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

# ns_stack_on_base <open prs json> <base branch> <fix pattern> <feature pattern> <prefix> [repo] [closed list json]:
# keep the run PRs whose chain belongs to the base branch: a stack belongs to one base branch. A chain's
# bottom PR targets the base branch, or a run branch without an open PR: then the base is resolved through
# the closed PRs (closed or merged) of that head, following their bases until the base branch (kept), another
# branch (dropped) or a run branch whose PR is not found in the closed list (kept with base_unknown: true; the
# caller escalates). The first closed PR must have been closed at or after the bottom PR was created (a
# reused name does not count). Without a closed list it is fetched from the repo when needed. PRs whose
# bases form a cycle have no bottom and are kept.
ns_stack_on_base() {
  local prs="$1" basebr="$2" fixpat="$3" featpat="$4" prefix="$5" repo="${6:-}" cl="${7:-}" fre ere since
  fre=$(ns_stack_pattern_re "$fixpat" "$prefix")
  ere=$(ns_stack_pattern_re "$featpat" "$prefix")
  prs=$(jq -c '. as $all
    | def up($p): [$all[] | select(.head == $p.base)] | first;
      def bottom($p; $seen): up($p) as $b
        | if $b == null then $p elif any($seen[]; . == $b.head) then null else bottom($b; $seen + [$b.head]) end;
    map(bottom(.; [.head]) as $b | . + {bottom: $b.base, bottomCreated: $b.createdAt})' <<<"$prs")
  if [ -z "$cl" ]; then
    cl="[]"
    since=$(jq -r --arg base "$basebr" --arg f "$fre" --arg e "$ere" '[.[] | select(.bottom != null and .bottom != $base
      and (.bottom | test($f) or test($e))) | .bottomCreated] | min // empty' <<<"$prs")
    if [ -n "$since" ] && [ -n "$repo" ]; then cl=$(ns_stack_closed_list "$repo" "$since"); fi
  fi
  jq -c --arg base "$basebr" --arg f "$fre" --arg e "$ere" --argjson cl "$cl" '
    def isrun($b): ($b | test($f) or test($e));
    def res($b; $created; $seen; $first):
      if $b == $base then "base"
      elif isrun($b) | not then "other"
      elif any($seen[]; . == $b) then "unknown"
      else ([$cl[] | select(.headRefName == $b and (($first | not) or .closedAt >= $created))] | sort_by(.closedAt) | last) as $c
        | if $c == null or ($c.baseRefName // null) == null then "unknown" else res($c.baseRefName; $created; $seen + [$b]; false) end
      end;
    map((if .bottom == null then "base" else res(.bottom; .bottomCreated; []; true) end) as $r
      | select($r != "other") | del(.bottom, .bottomCreated) | if $r == "unknown" then . + {base_unknown: true} else . end)' <<<"$prs"
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
# When bases form a cycle it warns on stderr naming the PRs in the cycle: a path down from a leaf stops
# before it repeats a PR, and a PR of a cycle that no chain reaches is listed on its own.
ns_stack_chains() {
  local out cyc
  out=$(jq -c '. as $all
    | def up($p): [$all[] | select(.head == $p.base)] | first;
      def path($p; $seen): up($p) as $b
        | if $b == null or any($seen[]; . == $b.head) then [$p] else path($b; $seen + [$b.head]) + [$p] end;
    [.[] as $p | select(any($all[]; .base == $p.head) | not) | path($p; [$p.head])] as $c
    | ([$c[][] | .number]) as $in
    | $c + [$all[] | select(.number as $n | any($in[]; . == $n) | not) | [.]]' <<<"$1")
  cyc=$(jq -r '. as $all
    | def up($p): [$all[] | select(.head == $p.base)] | first;
      def path($p; $seen): up($p) as $b
        | if $b == null or any($seen[]; . == $b.head) then [$p] else path($b; $seen + [$b.head]) + [$p] end;
    [.[] | . as $p | path($p; [$p.head]) as $pa | up($pa[0]) as $b
      | select($b != null and $b.head == $p.head) | "#\(.number)"] | join(", ")' <<<"$1")
  if [ -n "$cyc" ]; then
    printf 'warning: the bases of the open run PRs %s form a cycle: retarget one of them by hand\n' "$cyc" >&2
  fi
  printf '%s\n' "$out"
}

# ns_stack_closed_list <repo> [since]: JSON array of the closed PRs, merged or not (number, headRefName,
# baseRefName, closedAt, merged), all pages of a GitHub search (at most 1000 results); with since (UTC time)
# only those closed then or later. When the search fails it warns on stderr and prints [].
ns_stack_closed_list() {
  local q="repo:$1 is:pr is:closed" out
  [ -z "${2:-}" ] || q="$q closed:>=$2"
  # shellcheck disable=SC2016
  if ! out=$(gh api graphql --paginate -f q="$q" -f query='query ClosedRunPRs($q: String!, $endCursor: String) {
  search(query: $q, type: ISSUE, first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest { number headRefName baseRefName state mergedAt closedAt } } } }' \
    --jq '.data.search.nodes[]' 2>/dev/null) || ! out=$(jq -sc '[.[] | select(.number != null)
    | {number, headRefName, baseRefName, closedAt: (.closedAt // "9999"), merged: (.mergedAt != null or .state == "MERGED")}]' <<<"$out" 2>/dev/null); then
    printf 'warning: could not search the closed PRs of %s: closed and merged bases are not checked\n' "$1" >&2
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "$out"
}

# ns_stack_closed_candidates <open prs json> [base branch] [fix pattern feature pattern prefix]: JSON array of
# the bases of the open run PRs that could be a closed PR: not the base branch, and no open PR has that head
# (a reused name); with the patterns, only run branches
ns_stack_closed_candidates() {
  local fre="" ere=""
  if [ $# -ge 5 ]; then
    fre=$(ns_stack_pattern_re "$3" "$5")
    ere=$(ns_stack_pattern_re "$4" "$5")
  fi
  jq -c --arg b "${2:-}" --arg f "$fre" --arg e "$ere" '. as $all | [.[] | .base | select(. != $b)
    | select(. as $x | any($all[]; .head == $x) | not)
    | select($f == "" or test($f) or test($e))] | unique' <<<"$1" 2>/dev/null || printf '[]\n'
}

# ns_stack_closed_since <open prs json> <candidates json>: the earliest creation time of a PR on a candidate base
ns_stack_closed_since() {
  jq -r --argjson c "$2" '[.[] | select(.base as $b | any($c[]; . == $b)) | .createdAt] | min // empty' <<<"$1"
}

# ns_stack_closed_heads <repo> <open prs json> [base branch] [closed list json]: print the bases of the
# open run PRs that are a PR closed without a merge. A base counts when it is not the base branch, no open
# PR has that head (a reused name) and a closed unmerged PR has that head and was closed at or after the
# dependent PR was created. When not given, the closed list is fetched from the time the earliest such
# dependent PR was created on.
ns_stack_closed_heads() {
  local repo="$1" prs="$2" basebr="${3:-}" cl="${4:-}" cands
  cands=$(ns_stack_closed_candidates "$prs" "$basebr")
  [ "$cands" != '[]' ] || return 0
  [ -n "$cl" ] || cl=$(ns_stack_closed_list "$repo" "$(ns_stack_closed_since "$prs" "$cands")")
  jq -r --argjson prs "$prs" --argjson cands "$cands" 'map(select(.merged | not)) as $cl
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
  ns_stack_on_base "$prs" "$(jq -r '.git.base_branch' <<<"$prof")" "$fixpat" "$featpat" "$prefix" "$(jq -r .repo <<<"$p")"
}

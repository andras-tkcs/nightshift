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
# A chain starts at a PR whose base is not the head of another run PR.
ns_stack_chains() {
  jq -c '. as $all | length as $max
    | def root($p; $n): if $n <= 0 then $p.head
        else ([$all[] | select(.head == $p.base)] | first) as $b
          | if $b == null then $p.head else root($b; $n - 1) end end;
    map(. + {root: root(.; $max)}) as $m
    | (reduce $m[] as $r ([]; if any(.[]; . == $r.root) then . else . + [$r.root] end)) as $roots
    | [$roots[] as $x | [$m[] | select(.root == $x) | del(.root)]]' <<<"$1"
}

# ns_stack_closed_heads <repo>: print the head branches of PRs closed without a merge
ns_stack_closed_heads() {
  gh pr list --repo "$1" --state closed --limit 100 --json number,headRefName,state,mergedAt 2>/dev/null \
    | jq -r '.[] | select((.state // "") == "CLOSED" and .mergedAt == null) | .headRefName' 2>/dev/null || true
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

# ns_stack_project_prs <project json>: print the open run PRs of the project (JSON array, bottom to top)
ns_stack_project_prs() {
  local p="$1" prof path prefix branch
  path=$(jq -r .path <<<"$p")
  prefix=$(jq -r .prefix <<<"$p")
  branch=$(jq -r '.branch // ""' <<<"$p")
  prof=$(ns_profile_json "$path" "$prefix" "$branch" 2>/dev/null) || [ $? -eq 3 ] || return 1
  ns_stack_open_prs "$(jq -r .repo <<<"$p")" "$(jq -r '.git.fix_branch' <<<"$prof")" \
    "$(jq -r '.git.feature_branch' <<<"$prof")" "$prefix" "$path"
}

# shellcheck shell=bash
# Stacked run PRs: find the open PRs of Nightshift runs and order them as one line
# main <- a <- b. Functions only; source this file. Needs common.sh.

# ns_stack_pattern_re <pattern> <prefix>: print the regex for a branch-name pattern;
# {slug} is a run id of the prefix, {n} the run number
ns_stack_pattern_re() {
  local pat="$1" prefix="$2" re
  re=$(printf '%s' "$pat" | sed 's/[][\.*^$+?()|]/\\&/g')
  re=${re//\{slug\}/($prefix-[0-9a-z]+)}
  re=${re//\{n\}/([0-9a-z]+)}
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

# ns_stack_open_prs <repo> <fix pattern> <feature pattern> <prefix>: JSON array of the open
# run PRs, bottom to top: {run, number, head, base, createdAt, reviewDecision, statusCheckRollup}.
# Depth is the number of PRs below it (following baseRefName); ties go by creation time.
ns_stack_open_prs() {
  local repo="$1" fixpat="$2" featpat="$3" prefix="$4" prs rows="[]" row head rid
  prs=$(gh pr list --repo "$repo" --state open --limit 100 \
    --json number,headRefName,baseRefName,createdAt,reviewDecision,statusCheckRollup) || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    head=$(jq -r .headRefName <<<"$row")
    rid=$(ns_stack_run_id "$fixpat" "$featpat" "$prefix" "$head") || continue
    rows=$(jq -c --argjson r "$row" --arg rid "$rid" \
      '. + [{run: $rid, number: $r.number, head: $r.headRefName, base: $r.baseRefName,
        createdAt: $r.createdAt, reviewDecision: ($r.reviewDecision // ""),
        statusCheckRollup: ($r.statusCheckRollup // [])}]' <<<"$rows")
  done < <(jq -c '.[]' <<<"$prs")
  jq -c '. as $all
    | def depth($p; $n): if $n <= 0 then 0
        else ([$all[] | select(.head == $p.base)] | first) as $b
          | if $b == null then 0 else 1 + depth($b; $n - 1) end end;
    map(. + {depth: depth(.; length)}) | sort_by([.depth, .createdAt]) | map(del(.depth))' <<<"$rows"
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

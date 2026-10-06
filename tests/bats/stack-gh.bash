# shellcheck shell=bash
# gh stub answers for the PR lists of bin/lib/stack-pr.sh (GraphQL, paged with --paginate).
# The fixtures are written in the flat `gh pr list --json` shape and converted here.

# gql_open_pages <flat json>: print the pages (100 PRs each) of the OpenRunPRs query, one JSON document each,
# as `gh api graphql --paginate` prints them
gql_open_pages() {
  jq -c '[.[] | {number, headRefName, baseRefName, createdAt,
      reviewDecision: (if (.reviewDecision // "") == "" then null else .reviewDecision end),
      commits: {nodes: [{commit: {statusCheckRollup:
        (if (.statusCheckRollup // []) == [] then null else {contexts: {nodes: .statusCheckRollup}} end)}}]}}]
    | . as $a | ([range(0; length; 100)] | if length == 0 then [0] else . end) | .[] as $i
    | {data: {repository: {pullRequests: {pageInfo: {hasNextPage: ($i + 100 < ($a | length)), endCursor: "c\($i)"},
        nodes: $a[$i:$i + 100]}}}}' <<<"$1"
}

# gql_closed_pages <flat json>: the same for the ClosedRunPRs search (number, headRefName, state, mergedAt, closedAt)
gql_closed_pages() {
  jq -c '. as $a | ([range(0; length; 100)] | if length == 0 then [0] else . end) | .[] as $i
    | {data: {search: {pageInfo: {hasNextPage: ($i + 100 < ($a | length)), endCursor: "c\($i)"},
        nodes: [$a[$i:$i + 100][] | {number, headRefName, state, mergedAt, closedAt: (.closedAt // null)}]}}}' <<<"$1"
}

# stub_open_prs <flat json> <map line position: append | prepend>: answer the OpenRunPRs query
stub_open_prs() {
  printf '%s\n' "$1" >"$GH_STUB_RESPONSES/pr-list.flat.json"
  gql_open_pages "$1" >"$GH_STUB_RESPONSES/pr-list.json"
  stub_map_line '0\tpr-list.json\t^api graphql .*OpenRunPRs\n' "${2:-append}"
}

# stub_closed_prs <flat json>: answer the ClosedRunPRs search (always ahead of the other lines)
stub_closed_prs() {
  gql_closed_pages "$1" >"$GH_STUB_RESPONSES/pr-closed.json"
  stub_map_line '0\tpr-closed.json\t^api graphql .*ClosedRunPRs\n' prepend
}

# stub_map_line <printf format> <append | prepend>
stub_map_line() {
  if [ "$2" = prepend ]; then
    # shellcheck disable=SC2059
    { printf "$1"; cat "$GH_STUB_RESPONSES/map"; } >"$GH_STUB_RESPONSES/map.new"
    mv "$GH_STUB_RESPONSES/map.new" "$GH_STUB_RESPONSES/map"
  else
    # shellcheck disable=SC2059
    printf "$1" >>"$GH_STUB_RESPONSES/map"
  fi
}

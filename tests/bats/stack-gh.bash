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

# gql_closed_pages <flat json>: the same for the ClosedRunPRs search (number, headRefName, baseRefName, state,
# mergedAt, closedAt); a fixture without baseRefName gives null (a base the search did not report)
gql_closed_pages() {
  jq -c '. as $a | ([range(0; length; 100)] | if length == 0 then [0] else . end) | .[] as $i
    | {data: {search: {pageInfo: {hasNextPage: ($i + 100 < ($a | length)), endCursor: "c\($i)"},
        nodes: [$a[$i:$i + 100][] | {number, headRefName, baseRefName: (.baseRefName // null), state, mergedAt, closedAt: (.closedAt // null)}]}}}' <<<"$1"
}

# The stub answers only a query that pages: --paginate, after: $endCursor and pageInfo { hasNextPage endCursor }
STUB_PAGED='.*after: [$]endCursor.*pageInfo [{] hasNextPage endCursor [}]'

# stub_open_prs <flat json> <map line position: append | prepend>: answer the OpenRunPRs query
stub_open_prs() {
  printf '%s\n' "$1" >"$GH_STUB_RESPONSES/pr-list.flat.json"
  gql_open_pages "$1" >"$GH_STUB_RESPONSES/pr-list.json"
  stub_map_line 0 pr-list.json "^api graphql --paginate .*OpenRunPRs" "${2:-append}"
}

# stub_closed_prs <flat json>: answer the ClosedRunPRs search (always ahead of the other lines)
stub_closed_prs() {
  gql_closed_pages "$1" >"$GH_STUB_RESPONSES/pr-closed.json"
  stub_map_line 0 pr-closed.json "^api graphql --paginate .*ClosedRunPRs" prepend
}

# stub_map_line <exit code> <response file> <regex prefix> <append | prepend>: add a map line whose regex is
# the prefix followed by STUB_PAGED (the gh call must also contain the paging pieces)
stub_map_line() {
  local line
  line=$(printf '%s\t%s\t%s' "$1" "$2" "$3$STUB_PAGED")
  if [ "$4" = prepend ]; then
    { printf '%s\n' "$line"; cat "$GH_STUB_RESPONSES/map"; } >"$GH_STUB_RESPONSES/map.new"
    mv "$GH_STUB_RESPONSES/map.new" "$GH_STUB_RESPONSES/map"
  else
    printf '%s\n' "$line" >>"$GH_STUB_RESPONSES/map"
  fi
}

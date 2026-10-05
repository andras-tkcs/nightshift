# shellcheck shell=bash
# summary: write a run's time report from its ledger

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"

ns_report_help() {
  printf 'usage: ns report <id>\n\n'
  printf 'Build runs/<id>/run-report.md from the run ledger and print where it was written:\n'
  printf 'a summary (wall, active and waiting time, budget, review rounds, escalations) and\n'
  printf 'a timeline with one row per step. Works mid-run. When the worktree is gone the\n'
  printf 'ledger is read from origin/<plan branch> and the report goes to\n'
  printf '<config dir>/reports/<id>/run-report.md. Publish it with ns publish <id> RUN/run-report.md.\n'
}

# ns_report_cause <escalation.md text on stdin>: first heading, without a leading "Escalation:"
ns_report_cause() {
  sed -n 's/^# *//p' | head -n1 | sed -E 's/^[Ee]scalation:? *//; s/[[:space:]]+$//'
}

ns_report_main() {
  local u="ns report <id>"
  [ $# -eq 1 ] && [[ $1 != -* ]] || ns_usage "$u"
  local id="$1" entry wt ledger dir out json cause="" end last state tmp project path branch rel
  entry=$(ns_run_get "$id") || ns_die "unknown run $id"
  wt=$(jq -r .worktree <<<"$entry")
  ledger=$(ns_run_ledger "$id")
  rel=".nightshift/runs/$id"
  if [ -f "$ledger" ]; then
    json=$("$NS_HOME/bin/ns-ledger" get "$ledger") || exit 1
    dir=$(dirname "$ledger")
    [ ! -f "$dir/escalation.md" ] || cause=$(ns_report_cause <"$dir/escalation.md")
    out="$dir/run-report.md"
  else
    project=$(jq -r .project <<<"$entry")
    path=$(ns_project_by_name "$project" | jq -r '.path // empty') || path=""
    branch=$(jq -r .branch <<<"$entry")
    [ -n "$path" ] && [ -d "$path" ] || ns_die "no ledger for $id: worktree $wt is gone and project $project has no checkout"
    git -C "$path" fetch -q origin "$branch" 2>/dev/null || true
    tmp="$(mktemp)"
    git -C "$path" show "origin/$branch:$rel/ledger.yaml" >"$tmp" 2>/dev/null ||
      { rm -f "$tmp"; ns_die "no ledger for $id: not in $wt or on origin/$branch"; }
    json=$(ns_yaml_json "$tmp") || { rm -f "$tmp"; ns_die "ledger of $id on origin/$branch does not parse"; }
    rm -f "$tmp"
    cause=$(git -C "$path" show "origin/$branch:$rel/escalation.md" 2>/dev/null | ns_report_cause) || cause=""
    out="$(ns_config_dir)/reports/$id/run-report.md"
    mkdir -p "$(dirname "$out")"
  fi
  last=$(jq -r '[.events[].time | fromdateiso8601] | max // 0' <<<"$json")
  state=$(jq -r .state <<<"$json")
  case "$state" in
    done | stopped | failed) end=$last ;;
    *)
      end=$(date -u -d "$(ns_now)" +%s)
      [ "$end" -ge "$last" ] || end=$last
      ;;
  esac
  tmp="$out.tmp.$$"
  jq -r --argjson end "$end" --arg cause "$cause" -f "$NS_HOME/bin/lib/report.jq" <<<"$json" >"$tmp" ||
    { rm -f "$tmp"; ns_die "could not build the report for $id"; }
  mv "$tmp" "$out"
  printf '%s\n' "$out"
}

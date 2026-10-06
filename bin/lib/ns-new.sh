# shellcheck shell=bash
# summary: start a run

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/stacks.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/profile.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/queue.sh"

NS_NEW_USAGE="ns new <prefix>-<n> | <prefix> \"<text>\" | <prefix>-onboard --onboard | <prefix> --from-desk <path.md> [--tier T0..T3] [--yes] [--allow-outside]"

ns_new_help() {
  printf 'usage: ns new <prefix>-<n> [--tier T0..T3] [--yes] [--now]\n'
  printf '       ns new <prefix> "<text>" [--tier T0..T3] [--yes] [--now]\n'
  printf '       ns new <prefix> --from-desk <path.md> [--allow-outside] [--tier T0..T3] [--yes] [--now]\n'
  printf '       ns new <prefix>-onboard --onboard\n\n'
  printf 'Create a run: worktree on plan/<id>, ledger, then a tmux session running the\n'
  printf 'conductor. Without --tier the conductor triages first and asks for the tier\n'
  printf '(--yes takes its recommendation). --from-desk uses a desk note (absolute, or\n'
  printf 'relative to the desk directory, and inside it unless --allow-outside) as the request; a\n'
  printf 'note that looks like it holds a token is refused; nothing is added to the repo.\n'
  printf 'At max_runs live conductors the run waits in the queue (ns dequeue); --now starts it anyway.\n'
}

# ns_new_start <id> <wt> <ledger> <now>: under the queue lock, start the conductor or queue the run
ns_new_start() {
  local id="$1" wt="$2" ledger="$3" now="$4" live
  if ns_tmux_has "$id"; then
    printf 'started %s in tmux session %s: ns attach %s\n' "$id" "$id" "$id"
    return 0
  fi
  live=$(ns_queue_live_count)
  if [ "$now" = false ] && [ "$live" -ge "$(ns_queue_max)" ]; then
    "$NS_HOME/bin/ns-ledger" set "$ledger" '.stop_requested = null | .queued_for_slot = true' || return 1
    "$NS_HOME/bin/ns-ledger" state "$ledger" queued --note "waiting for a free run slot" || return 1
    "$NS_HOME/bin/ns-ledger" event "$ledger" queued "waiting for a free run slot" || return 1
    "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push 9>&- || return 1
    ns_queue_msg "$id" "$live"
    return 10
  fi
  "$NS_HOME/bin/ns-ledger" set "$ledger" '.queued_for_slot = false' || return 1
  ns_tmux_start "$id" "$wt" "$NS_HOME/bin/ns-launch $id" || return 1
  printf 'started %s in tmux session %s: ns attach %s\n' "$id" "$id" "$id"
}

ns_new_main() {
  local arg="" text="" tier="" yes=false onboard=false now=false desk_file="" allow_outside=false
  local prefix n id project profile rc=0 path pname repo branch base plan_branch wt ledger hours
  local ans rec src known
  while [ $# -gt 0 ]; do
    case "$1" in
      --tier)
        [ $# -ge 2 ] || ns_usage "$NS_NEW_USAGE"
        tier="$2"
        shift 2
        ;;
      --yes | -y)
        yes=true
        shift
        ;;
      --now)
        now=true
        shift
        ;;
      --onboard)
        onboard=true
        shift
        ;;
      --allow-outside)
        allow_outside=true
        shift
        ;;
      --from-desk)
        [ $# -ge 2 ] && [ -z "$desk_file" ] || ns_usage "$NS_NEW_USAGE"
        desk_file="$2"
        shift 2
        ;;
      -*) ns_usage "$NS_NEW_USAGE" ;;
      *)
        if [ -z "$arg" ]; then
          arg="$1"
        elif [ -z "$text" ]; then
          text="$1"
        else
          ns_usage "$NS_NEW_USAGE"
        fi
        shift
        ;;
    esac
  done
  [ -n "$arg" ] || ns_usage "$NS_NEW_USAGE"
  if [ -n "$desk_file" ]; then
    [ -z "$text" ] && [ "$onboard" = false ] && [[ $arg =~ ^[a-z][a-z0-9]{0,9}$ ]] || ns_usage "$NS_NEW_USAGE"
    case "$desk_file" in
      /*) ;;
      *) desk_file="$(ns_desk_dir)/$desk_file" ;;
    esac
    [ -f "$desk_file" ] || ns_die "$desk_file: no such desk note"
    local real desk_real
    real=$(realpath -- "$desk_file") || ns_die "$desk_file: cannot resolve the path"
    desk_real=$(realpath -m -- "$(ns_desk_dir)")
    if [ "$allow_outside" = false ]; then
      case "$real" in
        "$desk_real"/*) ;;
        *) ns_die "$desk_file: outside the desk directory $desk_real; pass --allow-outside to use it anyway" ;;
      esac
    fi
    text=$(cat "$real")
    [[ $text =~ [^[:space:]] ]] || ns_die "$desk_file: the desk note is empty"
    ! ns_has_token "$text" || ns_die "$desk_file: looks like it contains a token; remove it first"
  fi
  if [ -n "$tier" ] && [[ ! $tier =~ ^T[0-3]$ ]]; then
    ns_usage "$NS_NEW_USAGE"
  fi
  [ -z "$tier" ] || [ "$onboard" = false ] || ns_usage "$NS_NEW_USAGE"

  # 1. parse; find the project
  if [[ $arg =~ ^[a-z][a-z0-9]{0,9}$ ]]; then
    [ -n "$text" ] && [ "$onboard" = false ] || ns_usage "$NS_NEW_USAGE"
    prefix="$arg"
    n=""
    id=""
  else
    [ -z "$text" ] || ns_usage "$NS_NEW_USAGE"
    read -r prefix n < <(ns_run_parse_id "$arg") || ns_usage "$NS_NEW_USAGE"
    id="$arg"
    if [ "$onboard" = true ]; then
      [ "$n" = onboard ] || ns_usage "$NS_NEW_USAGE"
    else
      [[ $n =~ ^[0-9]+$ ]] || ns_usage "$NS_NEW_USAGE"
    fi
  fi
  project=$(ns_project_by_prefix "$prefix") || ns_die "unknown prefix $prefix: add the project with ns project add"
  pname=$(jq -r .name <<<"$project")
  repo=$(jq -r .repo <<<"$project")
  path=$(jq -r .path <<<"$project")
  branch=$(jq -r '.branch // ""' <<<"$project")

  # 2. already known?
  if [ -n "$id" ] && known=$(ns_run_get "$id"); then
    if [ "$(jq -r '.archived // false' <<<"$known")" = true ]; then
      ns_die "run $id is archived (removed by ns rm or ns gc; it stays in ns ls --all): to start $id again, free the id with ns rm $id --forget --remote (deletes $(jq -r '.branch // "its plan branch"' <<<"$known") on origin), then ns new $id"
    fi
    if ns_tmux_has "$id"; then
      printf '%s is already running: ns attach %s\n' "$id" "$id"
      return 0
    fi
    ns_die "run $id exists: use ns resume $id"
  fi

  # 3. profile, worktree
  profile=$(ns_profile_json "$path" "$prefix" "$branch") || rc=$?
  if [ "$rc" -eq 3 ] && [ "$onboard" = false ]; then
    local obpr="" oblg
    if ns_run_get "$prefix-onboard" >/dev/null && oblg=$(ns_run_ledger "$prefix-onboard") && [ -f "$oblg" ]; then
      obpr=$("$NS_HOME/bin/ns-ledger" get "$oblg" '.pr // empty' 2>/dev/null) || obpr=""
    fi
    base=$(jq -r '.git.base_branch' <<<"$profile")
    if [ -n "$obpr" ]; then
      ns_die "onboarding PR $obpr is not merged yet: merge it, then run ns new again"
    fi
    ns_die "$repo has no profile on $base: ns project add starts onboarding, or run ns new $prefix-onboard --onboard"
  elif [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    ns_die "could not read the profile of $repo"
  fi
  if [ -z "$id" ]; then
    # the index only knows this machine's runs: skip numbers whose plan branch is on origin
    local k
    k=$(ns_run_next_x "$prefix")
    while git -C "$path" ls-remote --exit-code -q --heads origin \
      "$(ns_branch_name "$(jq -r '.git.plan_branch' <<<"$profile")" "$prefix-x$k")" >/dev/null 2>&1; do
      k=$((k + 1))
    done
    id="$prefix-x$k"
  fi
  base=$(jq -r '.git.base_branch' <<<"$profile")
  plan_branch=$(ns_branch_name "$(jq -r '.git.plan_branch' <<<"$profile")" "$id")
  wt=$(ns_run_worktree_path "$profile" "$id")
  git -C "$path" fetch -q origin "$base" || ns_die "could not fetch origin $base in $path"
  mkdir -p "$(dirname "$wt")"
  git -C "$path" worktree add -q -b "$plan_branch" "$wt" "origin/$base" || ns_die "could not create worktree $wt"
  if jq -e '((.stacks | length) > 0) or ((.commands.setup // "") != "")' <<<"$profile" >/dev/null; then
    ns_stack_setup "$wt" "$profile" || ns_die "setup failed for $id"
  fi

  # 4. ledger, tier, index
  ledger="$wt/.nightshift/runs/$id/ledger.yaml"
  if [ "$onboard" = true ]; then
    "$NS_HOME/bin/ns-ledger" init "$ledger" --id "$id" --project "$pname" --text "onboard $repo" --branch "$plan_branch"
    tier=T1
  elif [[ $n =~ ^[0-9]+$ ]]; then
    "$NS_HOME/bin/ns-ledger" init "$ledger" --id "$id" --project "$pname" --issue "$n" --branch "$plan_branch"
  else
    "$NS_HOME/bin/ns-ledger" init "$ledger" --id "$id" --project "$pname" --text "$text" --branch "$plan_branch"
  fi
  if [ -n "$tier" ]; then
    hours=$(jq -r --arg t "$tier" '.budgets[$t].hours' <<<"$profile")
    "$NS_HOME/bin/ns-ledger" tier "$ledger" "$tier" --source owner --hours "$hours"
  fi
  "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push
  ns_run_register "$(jq -nc --arg i "$id" --arg p "$pname" --arg w "$wt" --arg b "$plan_branch" --arg c "$(ns_now)" \
    '{id: $i, project: $p, worktree: $w, branch: $b, created: $c, archived: false}')"

  # 5. triage before detaching
  if [ -z "$tier" ]; then
    "$NS_HOME/bin/ns-launch" "$id" --triage || ns_die "triage of $id failed: see $(ns_config_dir)/logs/$id/conductor.jsonl"
    [ ! -f "$wt/.nightshift/runs/$id/triage.md" ] || head -n 12 "$wt/.nightshift/runs/$id/triage.md"
    rec=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.tier_recommended // empty')
    [[ $rec =~ ^T[0-3]$ ]] || ns_die "triage of $id left no tier recommendation: ns resume $id after setting a tier"
    ans=""
    if [ "$yes" = false ]; then
      hours=$(jq -r --arg t "$rec" '.budgets[$t].hours' <<<"$profile")
      printf 'Run %s as %s (budget %s h)? [Y/n/T0/T1/T2/T3] ' "$id" "$rec" "$hours" >&2
      read -r ans || ans=""
      printf '\n' >&2
    fi
    ans=${ans^^}
    case "$ans" in
      "" | Y | YES)
        tier="$rec"
        src=triage
        ;;
      N | NO)
        "$NS_HOME/bin/ns-ledger" state "$ledger" stopped --note "owner declined the triage recommendation"
        "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push
        printf 'stopped; ns resume %s after setting a tier with ns new … --tier\n' "$id"
        return 0
        ;;
      T[0-3])
        tier="$ans"
        src=owner
        ;;
      *) ns_die "unrecognised answer: $ans" ;;
    esac
    hours=$(jq -r --arg t "$tier" '.budgets[$t].hours' <<<"$profile")
    "$NS_HOME/bin/ns-ledger" tier "$ledger" "$tier" --source "$src" --hours "$hours"
    "$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push
  fi

  # 6. detach
  rc=0
  ns_queue_locked ns_new_start "$id" "$wt" "$ledger" "$now" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ] || return "$rc"
}

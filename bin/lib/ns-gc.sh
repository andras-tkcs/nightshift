# shellcheck shell=bash
# summary: housekeeping (daily timer)

# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/runs.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/desk.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/stacks.sh"
# shellcheck source=/dev/null
source "$NS_HOME/bin/lib/profile.sh"

ns_gc_help() {
  printf 'usage: ns gc [--dry-run] [--monthly]\n\n'
  printf 'Housekeeping, run daily by a systemd timer. Removes worktrees, local and remote\n'
  printf 'plan/phase branches and tmux sessions of done runs whose PR is merged (for a closed PR\n'
  printf 'only the local work; the remote branches stay),\n'
  printf 'archives their desk folders, drops desk archives older than 90 days, and reports\n'
  printf 'work that needs you. --monthly (or day 01) also clears the stacks gc targets.\n'
  printf '--dry-run prints "would remove" lines and changes nothing.\n'
}

GC_DRY=0
GC_FREED=0
GC_NEEDS=0
GC_ERRORS=0

# gc_size <path>: bytes used, 0 when unreadable
gc_size() {
  local n
  n=$(du -sb "$1" 2>/dev/null | cut -f1) || n=0
  printf '%s\n' "${n:-0}"
}

# gc_say <kind> <target>
gc_say() {
  if [ "$GC_DRY" = 1 ]; then
    printf 'would remove %s %s\n' "$1" "$2"
  else
    printf 'remove %s %s\n' "$1" "$2"
  fi
}

# gc_needs <target> <reason>
gc_needs() {
  printf 'needs you: %s: %s\n' "$1" "$2"
  GC_NEEDS=$((GC_NEEDS + 1))
}

# gc_work_state <dir>: prints the reason when the worktree has uncommitted or unpushed work
gc_work_state() {
  if [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]; then
    printf 'uncommitted changes\n'
  elif [ -n "$(git -C "$1" log --oneline HEAD --not --remotes 2>/dev/null)" ]; then
    printf 'unpushed commits\n'
  fi
}

# gc_human <bytes>
gc_human() {
  if [ "$1" -lt 1024 ]; then
    printf '%sB\n' "$1"
  else
    numfmt --to=iec --suffix=B "$1"
  fi
}

# gc_run_inner <run-json>: step 1 for one run (the owner token is already exported)
gc_run_inner() {
  local run="$1" id pname base proj path ledger state pr prstate
  id=$(jq -r .id <<<"$run")
  pname=$(jq -r .project <<<"$run")
  base=$(jq -r '.worktree // ""' <<<"$run")
  proj=$(ns_project_by_name "$pname") || return 0
  path=$(jq -r .path <<<"$proj")
  [ -n "$base" ] || return 0
  ledger="$base/.nightshift/runs/$id/ledger.yaml"
  [ -f "$ledger" ] || return 0
  state=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.state // ""' 2>/dev/null) || return 0
  [ "$state" = "done" ] || return 0
  pr=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.pr // ""' 2>/dev/null) || return 0
  [ -n "$pr" ] || return 0
  prstate=$(gh pr view "$pr" --json state -q .state 2>/dev/null) || {
    gc_needs "$id" "cannot read PR state"
    return 0
  }
  case "$prstate" in MERGED | CLOSED) ;; *) return 0 ;; esac
  # remote branches go only after a merge; a closed PR keeps them (plan/<id> is the ledger)
  local remote=0
  if [ "$prstate" = MERGED ]; then
    remote=1
  else
    printf 'kept remote branches of %s (PR closed, not merged)\n' "$id"
  fi
  gc_cleanup_run "$run" "$proj" "$remote" 0 || return 0
}

# gc_run_profile <proj-json>: the project's resolved profile JSON, empty when it cannot be read
gc_run_profile() {
  local out rc=0
  out=$(ns_profile_json "$(jq -r .path <<<"$1")" "$(jq -r .prefix <<<"$1")" "$(jq -r '.branch // ""' <<<"$1")" 2>/dev/null) || rc=$?
  if { [ "$rc" = 0 ] || [ "$rc" = 3 ]; } && jq -e '.git | type == "object"' >/dev/null 2>&1 <<<"$out"; then
    printf '%s\n' "$out"
  fi
}

# gc_own_branch <profile-json> <id> <code|phase> <branch>: 0 when the branch is the run's own
# fix or feature branch (code) or a phase branch of it (phase), as the profile names them
gc_own_branch() {
  local prof="$1" id="$2" kind="$3" b="$4" t pre suf mid
  case "$b" in "" | -*) return 1 ;; esac
  [ -n "$prof" ] || return 1
  if [ "$kind" = code ]; then
    for t in fix_branch feature_branch; do
      t=$(jq -r ".git.$t // empty" <<<"$prof")
      [ -z "$t" ] || [ "$b" != "$(ns_branch_name "$t" "$id")" ] || return 0
    done
    return 1
  fi
  t=$(jq -r '.git.phase_branch // empty' <<<"$prof")
  [[ $t == *"{phase}"* ]] || return 1
  pre=$(ns_branch_name "${t%%"{phase}"*}" "$id")
  suf=$(ns_branch_name "${t#*"{phase}"}" "$id")
  [[ $b == "$pre"*"$suf" ]] || return 1
  mid=${b#"$pre"}
  mid=${mid%"$suf"}
  [[ $mid =~ ^[A-Za-z0-9._-]+$ ]]
}

# gc_cleanup_run <run-json> <proj-json> <remote:0|1|2> <force:0|1> [ledger]: removes the run's
# worktrees, local branches, (with remote=1) remote branches, tmux session and desk folder, and
# marks it archived. Unsaved work in a worktree keeps the run whole (return 2) unless force=1.
# The ledger defaults to the one in the run worktree; without one only the plan branch is known.
gc_cleanup_run() {
  local run="$1" proj="$2" remote="$3" force="$4" ledger="${5:-}" id pname base path
  id=$(jq -r .id <<<"$run")
  pname=$(jq -r .project <<<"$run")
  base=$(jq -r '.worktree // ""' <<<"$run")
  path=$(jq -r .path <<<"$proj")
  [ -n "$ledger" ] || ledger="$base/.nightshift/runs/$id/ledger.yaml"

  local -a wts=() locals=() remotes=() phases=()
  local plan feature="" b wpath line why dest month src sz basebranch keep=0 prof="" n
  plan=$(jq -r '.branch // ""' <<<"$run")
  if [ -f "$ledger" ]; then
    feature=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.feature_branch // ""')
    mapfile -t phases < <("$NS_HOME/bin/ns-ledger" get "$ledger" '.phases[]?.branch // empty')
  fi
  # the ledger is written by agents: only branch names the profile gives this run are touched
  if [ -n "$feature" ] || [ "${#phases[@]}" -gt 0 ]; then
    prof=$(gc_run_profile "$proj")
  fi
  if [ -n "$plan" ]; then
    locals+=("$plan")
    remotes+=("$plan")
  fi
  if [ -n "$feature" ]; then
    if gc_own_branch "$prof" "$id" code "$feature"; then
      locals+=("$feature")
      # ns rm (remote=2) also deletes the feature branch on origin; gc leaves it to the merge
      if [ "$remote" = 2 ]; then remotes+=("$feature"); fi
    else
      ns_warn "$id: skipped branch $feature: not a branch of $id"
    fi
  fi
  for b in "${phases[@]}"; do
    [ -n "$b" ] || continue
    if gc_own_branch "$prof" "$id" phase "$b"; then
      locals+=("$b")
      remotes+=("$b")
    else
      ns_warn "$id: skipped branch $b: not a branch of $id"
    fi
  done

  # (a) worktrees: the run's own path or <path>--<suffix>, never a bare prefix
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wpath=${line#worktree }
        if [ "$wpath" != "$path" ] && { [ "$wpath" = "$base" ] || [[ $wpath == "$base"--* ]]; }; then
          wts+=("$wpath")
        fi
        ;;
    esac
  done < <(git -C "$path" worktree list --porcelain 2>/dev/null)

  if [ "$force" != 1 ]; then
    for wpath in "${wts[@]}"; do
      why=$(gc_work_state "$wpath")
      if [ -n "$why" ]; then
        gc_needs "$wpath" "$why"
        keep=1
      fi
    done
  fi
  [ "$keep" = 0 ] || return 2

  local -a wtflag=()
  if [ "$force" = 1 ]; then wtflag=(--force); fi
  for wpath in "${wts[@]}"; do
    sz=$(gc_size "$wpath")
    GC_FREED=$((GC_FREED + sz))
    gc_say worktree "$wpath"
    if [ "$GC_DRY" = 0 ] && ! git -C "$path" worktree remove "${wtflag[@]}" "$wpath" 2>/dev/null; then
      ns_warn "could not remove worktree $wpath"
      GC_ERRORS=$((GC_ERRORS + 1))
    fi
  done

  # the base branch is never deleted
  basebranch=$(jq -r '.branch // ""' <<<"$proj")
  if [ -z "$basebranch" ]; then
    basebranch=$(git -C "$path" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || basebranch=""
    basebranch=${basebranch#origin/}
  fi

  # (b) local branches
  for b in "${locals[@]}"; do
    [ "$b" != "$basebranch" ] || continue
    git -C "$path" show-ref -q --verify "refs/heads/$b" || continue
    gc_say branch "$b"
    if [ "$GC_DRY" = 0 ] && ! git -C "$path" branch -d "$b" >/dev/null 2>&1; then
      # plan and phase branches are never merged into the base; they count as safe when
      # everything on them is also on origin (their remote copy is deleted below)
      if [ "$force" = 1 ] || git -C "$path" merge-base --is-ancestor "$b" "origin/$b" 2>/dev/null; then
        git -C "$path" branch -D "$b" >/dev/null 2>&1 || gc_needs "$b" "could not delete local branch"
      else
        gc_needs "$b" "local branch is not fully merged"
      fi
    fi
  done

  # (c) remote branches: only when asked for (gc: after a merge)
  if [ "$remote" = 0 ]; then remotes=(); fi
  for b in "${remotes[@]}"; do
    [ "$b" != "$basebranch" ] || continue
    git -C "$path" ls-remote --exit-code --heads origin "$b" >/dev/null 2>&1 || continue
    gc_say remote-branch "origin/$b"
    if [ "$GC_DRY" = 0 ] && ! git -C "$path" push -q origin --delete "$b" 2>/dev/null; then
      ns_warn "could not delete origin/$b"
      GC_ERRORS=$((GC_ERRORS + 1))
    fi
  done

  # (d) tmux session
  if ns_tmux_has "$id"; then
    gc_say tmux "$id"
    if [ "$GC_DRY" = 0 ] && ! ns_tmux_kill "$id"; then
      GC_ERRORS=$((GC_ERRORS + 1))
    fi
  fi

  # (e) desk folder moves to the archive (moved, so not counted as freed)
  src=$(ns_desk_run_dir "$pname" "$id")
  month=$(ns_now | cut -c1-7)
  dest="$(ns_desk_dir)/$pname/archive/$month/$id"
  # a forgotten id can be used and removed again in the same month
  n=2
  while [ -e "$dest" ]; do
    dest="$(ns_desk_dir)/$pname/archive/$month/$id-$n"
    n=$((n + 1))
  done
  if [ -d "$src" ]; then
    gc_say desk "$src"
    if [ "$GC_DRY" = 0 ]; then
      mkdir -p "$(dirname "$dest")"
      if mv "$src" "$dest"; then
        touch "$dest"
      else
        GC_ERRORS=$((GC_ERRORS + 1))
      fi
    fi
  fi

  # (f) runs index, then the desk index
  if [ "$GC_DRY" = 0 ]; then
    ns_run_set "$id" '.archived = true'
    ns_desk_index "$pname"
  fi
}

# gc_run <run-json>: runs gc_run_inner with the project owner's token exported, then
# restores GH_TOKEN. The token never appears on a command line or in output.
gc_run() {
  local run="$1" repo owner id err had=0 saved="" rc=0
  id=$(jq -r .id <<<"$run")
  repo=$(ns_project_by_name "$(jq -r .project <<<"$run")" 2>/dev/null | jq -r '.repo // ""') || repo=""
  owner=${repo%%/*}
  if [ -n "${GH_TOKEN+x}" ]; then
    had=1
    saved=$GH_TOKEN
  fi
  if [ -n "$owner" ]; then
    # ns_token_export dies on a wrong file mode or the name ntfy, so probe it in a subshell
    # first and pass on its reason (it never contains the token)
    if ! err=$( (ns_token_export "$owner") 2>&1 >/dev/null); then
      err="${err%%$'\n'*}"
      gc_needs "$id" "token file for $owner is unusable: ${err#"${NS_CMD:-ns}: "}"
      return 0
    fi
    ns_token_export "$owner" >/dev/null 2>&1 || true
  fi
  "${GC_INNER:-gc_run_inner}" "$run" || rc=$?
  if [ "$had" = 1 ]; then export GH_TOKEN="$saved"; else unset GH_TOKEN; fi
  return "$rc"
}

ns_gc_main() {
  local u="ns gc [--dry-run] [--monthly]" monthly=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) GC_DRY=1 ;;
      --monthly) monthly=1 ;;
      *) ns_usage "$u" ;;
    esac
    shift
  done
  ns_load_env

  # 1. finished runs
  local run
  while IFS= read -r run; do
    [ -n "$run" ] || continue
    gc_run "$run"
  done < <(ns_runs_json | jq -c '.[] | select(.archived | not)')

  # 2. desk archives older than 90 days
  local d sz
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    sz=$(gc_size "$d")
    GC_FREED=$((GC_FREED + sz))
    gc_say archive "$d"
    if [ "$GC_DRY" = 0 ] && ! rm -rf "$d"; then
      GC_ERRORS=$((GC_ERRORS + 1))
    fi
  done < <(find "$(ns_desk_dir)" -mindepth 4 -maxdepth 4 -type d -path '*/archive/*/*' -mtime +90 2>/dev/null | sort)

  # 3. project worktrees holding work (report only)
  local proj ppath w why
  while IFS= read -r proj; do
    [ -n "$proj" ] || continue
    ppath=$(jq -r .path <<<"$proj")
    for w in "$ppath"/.claude/worktrees/*; do
      [ -d "$w" ] || continue
      why=$(gc_work_state "$w")
      if [ -n "$why" ]; then gc_needs "$w" "$why"; fi
    done
  done < <(ns_projects_json | jq -c '.[]')

  # 4. monthly stack targets
  local now t sf prof stk seen=" "
  now=$(ns_now)
  if [ "$monthly" = 1 ] || [ "${now:8:2}" = 01 ]; then
    while IFS= read -r proj; do
      [ -n "$proj" ] || continue
      prof=$(ns_profile_json "$(jq -r .path <<<"$proj")" "$(jq -r .prefix <<<"$proj")" "$(jq -r '.branch // ""' <<<"$proj")" 2>/dev/null) || true
      jq -e . >/dev/null 2>&1 <<<"$prof" || continue
      while IFS= read -r stk; do
        [ -n "$stk" ] || continue
        sf=$(ns_stack_file "$stk")
        [ -f "$sf" ] || continue
        while IFS= read -r t; do
          [ -n "$t" ] || continue
          t=$(ns_expand_path "$t")
          case "$t" in "" | / | "$HOME") continue ;; esac
          [ -e "$t" ] || continue
          case "$seen" in *" $t "*) continue ;; esac
          seen="$seen$t "
          sz=$(gc_size "$t")
          GC_FREED=$((GC_FREED + sz))
          gc_say cache "$t"
          if [ "$GC_DRY" = 0 ] && ! rm -rf "$t"; then
            GC_ERRORS=$((GC_ERRORS + 1))
          fi
        done < <(ns_yaml_json "$sf" | jq -r '.gc.monthly // [] | .[]')
      done < <(jq -r '.stacks[]? | if type == "object" then .name else . end' <<<"$prof")
    done < <(ns_projects_json | jq -c '.[]')
  fi

  # 6. disk and reboot
  local disk parts=""
  disk=$(df -P "$HOME" 2>/dev/null | awk 'NR==2 {gsub("%", "", $5); print $5}') || disk=""
  if [ "$GC_NEEDS" -gt 0 ]; then parts+=" · $GC_NEEDS item(s) need you"; fi
  if [ -e "${NS_REBOOT_FILE:-/var/run/reboot-required}" ]; then parts+=" · reboot required"; fi
  if [[ ${disk:-} =~ ^[0-9]+$ ]] && [ "$disk" -gt 80 ]; then
    printf 'disk %s%% full\n' "$disk"
    parts+=" · disk ${disk}%"
  fi

  # 7. summary
  local summary
  if [ "$GC_DRY" = 1 ]; then
    summary="ns gc (dry run): would free $(gc_human "$GC_FREED")$parts"
    printf '%s\n' "$summary"
  else
    summary="ns gc: freed $(gc_human "$GC_FREED")$parts"
    printf '%s\n' "$summary"
    "$NS_HOME/bin/ns-notify" "$summary" || ns_warn "could not send the notification"
  fi

  # 8. healthcheck
  if [ "$GC_DRY" = 0 ] && [ "$GC_ERRORS" = 0 ] && [ -n "${NS_HEALTHCHECK_URL:-}" ]; then
    curl -fsS -m 10 "$NS_HEALTHCHECK_URL" >/dev/null || ns_warn "healthcheck ping failed"
  fi
  [ "$GC_ERRORS" = 0 ]
}

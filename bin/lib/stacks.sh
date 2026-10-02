# shellcheck shell=bash
# Stack plugin helpers. Source this file; it defines functions only.

ns_stack_file() {
  printf '%s/plugins/ns-%s/stack.yaml\n' "$NS_HOME" "$1"
}

# ns_stack_setup <dir> <profile-json>
ns_stack_setup() {
  local dir="$1" profile="$2" logdir log cmd name sf
  local -a cmds=()
  logdir="$(ns_config_dir)/logs"
  mkdir -p "$logdir"
  log="$logdir/setup-$(basename "$dir").log"
  : >"$log"
  cmd=$(jq -r '.commands.setup // empty' <<<"$profile")
  if [ -n "$cmd" ]; then
    cmds+=("$cmd")
  else
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      sf="$(ns_stack_file "$name")"
      [ -f "$sf" ] || continue
      while IFS= read -r cmd; do
        [ -n "$cmd" ] && cmds+=("$cmd")
      done < <(ns_yaml_json "$sf" | jq -r '.setup // [] | .[]')
    done < <(jq -r '.stacks[]? | if type == "object" then .name else . end' <<<"$profile")
  fi
  for cmd in "${cmds[@]}"; do
    if ! (cd "$dir" && bash -c "$cmd") >>"$log" 2>&1; then
      printf 'setup failed in %s: %s (log: %s)\n' "$dir" "$cmd" "$log"
      return 1
    fi
  done
  return 0
}

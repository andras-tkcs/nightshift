# shellcheck shell=bash
# Config, project registry and tokens. Source this file; it defines functions only.

ns_config_get() {
  local key="$1" default="${2:-}" file val
  file="$(ns_config_dir)/config.yaml"
  if [ -f "$file" ]; then
    val=$(ns_yaml_json "$file" | jq -r --arg k "$key" '.[$k] // empty') || val=""
    if [ -n "$val" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi
  printf '%s\n' "$default"
}

ns_projects_json() {
  local file
  file="$(ns_config_dir)/projects.yaml"
  if [ -f "$file" ]; then
    ns_yaml_json "$file" | jq -c '.projects // []'
  else
    printf '[]\n'
  fi
}

ns_project_by_prefix() {
  local out
  out=$(ns_projects_json | jq -ce --arg p "$1" '.[] | select(.prefix == $p)') || return 1
  printf '%s\n' "$out"
}

ns_project_by_name() {
  local out
  out=$(ns_projects_json | jq -ce --arg n "$1" '.[] | select(.name == $n)') || return 1
  printf '%s\n' "$out"
}

# ns_project_register <json>: append, or no-op if an identical entry exists
ns_project_register() {
  local entry="$1" all new
  all=$(ns_projects_json)
  if jq -e --argjson e "$entry" 'any(.[]; . == $e)' <<<"$all" >/dev/null; then
    return 0
  fi
  new=$(jq -c --argjson e "$entry" '. + [$e] | {projects: .}' <<<"$all")
  mkdir -p "$(ns_config_dir)"
  ns_json_yaml "$(ns_config_dir)/projects.yaml" <<<"$new"
}

# ns_token_export <owner>: export GH_TOKEN from tokens/<owner> if the file exists
ns_token_export() {
  local file mode tok
  file="$(ns_config_dir)/tokens/$1"
  [ -f "$file" ] || return 0
  mode=$(stat -c %a "$file")
  [ "$mode" = 600 ] || ns_die "token file $file must be mode 600"
  IFS= read -r tok <"$file" || true
  tok="${tok#"${tok%%[![:space:]]*}"}"
  tok="${tok%"${tok##*[![:space:]]}"}"
  export GH_TOKEN="$tok"
}

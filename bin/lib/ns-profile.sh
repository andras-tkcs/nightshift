# shellcheck shell=bash
# summary: check or show a project profile

ns_profile_help() {
  printf 'usage: ns profile check [path] [--repo <dir>]\n       ns profile show [path]\n\n'
  printf 'check validates a project profile (path: a repo dir or a profile file, default .).\n'
  printf 'show prints the resolved profile as JSON.\n'
}

# resolve a repo dir or file argument to a profile file
ns_profile_file() {
  local p="$1"
  if [ -d "$p" ]; then
    p="$p/.claude/project-profile.yaml"
  fi
  [ -f "$p" ] || ns_die "no profile at $p"
  printf '%s\n' "$p"
}

ns_profile_main() {
  local sub="${1:-}" path=. repo="" file
  [ $# -gt 0 ] && shift
  case "$sub" in
    check)
      while [ $# -gt 0 ]; do
        case "$1" in
          --repo)
            [ $# -ge 2 ] || ns_usage "ns profile check [path] [--repo <dir>]"
            repo="$2"
            shift 2
            ;;
          -*) ns_usage "ns profile check [path] [--repo <dir>]" ;;
          *)
            path="$1"
            shift
            ;;
        esac
      done
      file=$(ns_profile_file "$path")
      if [ -n "$repo" ]; then
        python3 "$NS_HOME/bin/lib/profile.py" check "$file" --repo "$repo"
      else
        python3 "$NS_HOME/bin/lib/profile.py" check "$file"
      fi
      ;;
    show)
      [ $# -le 1 ] || ns_usage "ns profile show [path]"
      file=$(ns_profile_file "${1:-.}")
      python3 "$NS_HOME/bin/lib/profile.py" show "$file"
      ;;
    *) ns_usage "ns profile check [path] [--repo <dir>] | ns profile show [path]" ;;
  esac
}

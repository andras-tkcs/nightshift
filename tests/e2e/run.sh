#!/usr/bin/env bash
# End-to-end harness entry point (see docs/development.md, "End-to-end runs"). On ns-main only.
set -euo pipefail

readonly E2E_REPO=andras-tkcs/nightshift-sandbox

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/e2e/lib.sh
source "$here/lib.sh"

usage() {
  cat <<'EOF'
usage: tests/e2e/run.sh <t0|t1|t2|t3|stack|resume> [--keep]
       tests/e2e/run.sh preflight
       tests/e2e/run.sh cleanup <base branch>
       tests/e2e/run.sh --help

Runs one end-to-end scenario against the sandbox repository (a constant in this
script; nothing changes it). Appends a line to tests/e2e/results.md.
  --keep     on PASS leave the PR, its branches and the base branch in place
  preflight  check gh login, the sandbox repo, auto mode, bats, shellcheck and memory
  cleanup    remove what a failed attempt left on GitHub and on disk
EOF
}

die_usage() {
  usage >&2
  exit 2
}

require_repo() {
  gh repo view "$E2E_REPO" >/dev/null 2>&1 || {
    echo "e2e: cannot view $E2E_REPO with gh; refusing to run" >&2
    exit 1
  }
}

preflight() {
  local rc=0 avail tmp
  check() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
      printf 'ok    %s\n' "$name"
    else
      printf 'FAIL  %s\n' "$name"
      rc=1
    fi
  }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/e2e-preflight.XXXXXX")"
  check "gh auth status" gh auth status
  check "gh repo view $E2E_REPO" gh repo view "$E2E_REPO"
  check "ns-conductor check-auto" env NS_HOME="$E2E_REPO_ROOT" NS_CONFIG_DIR="$tmp" "$E2E_REPO_ROOT/bin/ns-conductor" check-auto
  check "bats is installed" command -v bats
  check "shellcheck is installed" command -v shellcheck
  avail=$(free -m | awk '/^Mem:/ {print $7}')
  if [ "${avail:-0}" -ge 1200 ]; then
    printf 'ok    memory available %s MB (need 1200)\n' "$avail"
  else
    printf 'FAIL  memory available %s MB (need 1200)\n' "${avail:-0}"
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

do_cleanup() {
  local base="$1" root
  [[ $base =~ ^e2e/[0-9]{8}-[0-9]+$ ]] || {
    echo "e2e: not an e2e base branch name: $base" >&2
    exit 2
  }
  require_repo
  root="$(e2e_root_for "$base")"
  e2e_remote_cleanup "$base" "$root"
  rm -rf "$root"
  echo "e2e: cleaned up $base"
}

run_scenario() {
  local scenario="$1" base start rc=0
  require_repo
  start=$SECONDS
  base="$(e2e_next_base)"
  e2e_env_setup "$base"
  e2e_log "scenario $scenario on $E2E_REPO base $base (root $E2E_ROOT)"
  # shellcheck source=/dev/null
  source "$here/scenarios/$scenario.sh"
  trap 'e2e_stop_run "$E2E_ID"' EXIT
  if e2e_create_base "$base" && e2e_project_add && scenario_main; then
    rc=0
  else
    rc=1
  fi
  trap - EXIT
  e2e_finish "$scenario" "$rc" "$start"
}

main() {
  [ $# -ge 1 ] || die_usage
  case "$1" in
    --help | -h)
      usage
      ;;
    preflight)
      [ $# -eq 1 ] || die_usage
      preflight
      ;;
    cleanup)
      [ $# -eq 2 ] || die_usage
      do_cleanup "$2"
      ;;
    t0 | t1 | t2 | t3 | stack | resume)
      local scenario="$1"
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --keep) E2E_KEEP=1 ;;
          *) die_usage ;;
        esac
        shift
      done
      run_scenario "$scenario"
      ;;
    *)
      die_usage
      ;;
  esac
}

main "$@"

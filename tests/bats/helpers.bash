# shellcheck shell=bash
# Shared helpers for every bats file. Written in full by p01; never edited afterwards.

NS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export NS_REPO_ROOT

ns_test_setup() {
  export NS_HOME="$NS_REPO_ROOT"
  export NS_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  export NS_DESK_DIR="$BATS_TEST_TMPDIR/desk"
  export NS_CODING_DIR="$BATS_TEST_TMPDIR/coding"
  export GH_STUB_REMOTES="$BATS_TEST_TMPDIR/remotes"
  export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh.log"
  export NS_STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  export NS_NOW=2026-10-02T21:00:00Z
  export HOME="$BATS_TEST_TMPDIR/home"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export TMUX_STUB_DIR="$BATS_TEST_TMPDIR/tmux"
  unset NS_NTFY_TOPIC NS_DESK_URL NS_HEALTHCHECK_URL NS_RUN_ID NS_LEDGER NS_WORKER \
    NS_PHASE GH_TOKEN NS_PLUGIN_DIRS NS_WORKER_MODE
  mkdir -p "$NS_CONFIG_DIR" "$NS_DESK_DIR" "$NS_CODING_DIR" "$GH_STUB_REMOTES" \
    "$HOME" "$TMUX_STUB_DIR"
  : >"$GH_STUB_LOG"
  : >"$NS_STUB_LOG"
  git config --file "$GIT_CONFIG_GLOBAL" user.name "Nightshift Test"
  git config --file "$GIT_CONFIG_GLOBAL" user.email "test@example.invalid"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  export PATH="$NS_REPO_ROOT/tests/fixtures/bin:$NS_REPO_ROOT/tests/fixtures/gh-stub:$NS_REPO_ROOT/bin:$PATH"
}

# make_remote <owner/repo> [<fixture dir>]
make_remote() {
  local slug="$1" fixture="${2:-}"
  local bare="$GH_STUB_REMOTES/$slug.git"
  local work
  work="$(mktemp -d "$BATS_TEST_TMPDIR/mkremote.XXXXXX")"
  mkdir -p "$(dirname "$bare")"
  git init -q --bare -b main "$bare"
  git init -q -b main "$work"
  if [ -n "$fixture" ]; then
    cp -a "$fixture"/. "$work"/
  else
    printf '# %s\n' "$slug" >"$work/README.md"
  fi
  git -C "$work" add -A
  git -C "$work" commit -q -m "Initial commit"
  git -C "$work" push -q "$bare" main
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  rm -rf "$work"
}

assert_success() {
  if [ "${status:-1}" -ne 0 ]; then
    echo "expected success, got status ${status:-unset}" >&2
    echo "output: ${output:-}" >&2
    return 1
  fi
}

# assert_failure [<status>]
assert_failure() {
  if [ "${status:-0}" -eq 0 ]; then
    echo "expected failure, got status 0" >&2
    echo "output: ${output:-}" >&2
    return 1
  fi
  if [ -n "${1:-}" ] && [ "$status" -ne "$1" ]; then
    echo "expected status $1, got $status" >&2
    echo "output: ${output:-}" >&2
    return 1
  fi
}

assert_output_contains() {
  case "${output:-}" in
    *"$1"*) ;;
    *) echo "output does not contain: $1" >&2; echo "output: ${output:-}" >&2; return 1 ;;
  esac
}

assert_output_not_contains() {
  case "${output:-}" in
    *"$1"*) echo "output contains: $1" >&2; echo "output: ${output:-}" >&2; return 1 ;;
  esac
}

# refute_token_in <file...>: fails if a file matches the token ERE of D1.
refute_token_in() {
  local f
  for f in "$@"; do
    if grep -Eq '(github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,})' "$f"; then
      echo "token pattern found in $f" >&2
      return 1
    fi
  done
}

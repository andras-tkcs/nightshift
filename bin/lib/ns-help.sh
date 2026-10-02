# shellcheck shell=bash
# summary: list commands

ns_help_help() {
  printf 'usage: ns help\n\nList every ns command with a one-line summary.\n'
}

ns_help_main() {
  local f name summary
  printf 'usage: ns <command> [args]\n\ncommands:\n'
  for f in "$NS_HOME"/bin/lib/ns-*.sh; do
    name=${f##*/ns-}
    name=${name%.sh}
    summary=$(sed -n 's/^# summary: //p' "$f" | head -n1)
    printf '  %-10s %s\n' "$name" "$summary"
  done
  printf '\nAlso on PATH: ns-notify, ns-ledger, ns-conductor, ns-launch, ns-gh, bootstrap.sh (root). See docs/usage.md.\n'
}

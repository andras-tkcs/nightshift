#!/usr/bin/env bats

load helpers

bats_require_minimum_version 1.5.0

setup() { ns_test_setup; }

@test "ns ls --help prints the --json line without printf errors" {
  run --separate-stderr ns ls --help
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"invalid option"* ]]
  [[ "$output" == *"--json prints an array"* ]]
}

@test "ns status --help prints the --json line without printf errors" {
  run --separate-stderr ns status --help
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"invalid option"* ]]
  [[ "$output" == *"--json prints the whole ledger"* ]]
}

@test "ns gc --help prints the --dry-run line without printf errors" {
  run --separate-stderr ns gc --help
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"invalid option"* ]]
  [[ "$output" == *"--dry-run prints"* ]]
}

@test "no printf in bin/ has a format starting with a dash and no --" {
  run grep -rnE "printf +(['\"])-" "$NS_REPO_ROOT/bin"
  [ "$status" -eq 1 ]
}

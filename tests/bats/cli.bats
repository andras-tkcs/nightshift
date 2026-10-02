#!/usr/bin/env bats

load helpers

setup() {
  ns_test_setup
}

@test "ns alone lists commands" {
  run ns
  [ "$status" -eq 0 ]
  [[ "$output" == *"commands:"* ]]
  [[ "$output" == *"  help       list commands"* ]]
}

@test "ns help lists commands" {
  run ns help
  [ "$status" -eq 0 ]
  [[ "$output" == *"commands:"* ]]
  [[ "$output" == *"  help       list commands"* ]]
}

@test "unknown command exits 2" {
  run ns nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command: nope"* ]]
}

@test "ns help --help prints usage" {
  run ns help --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: ns help"* ]]
}

@test "ns --help is help" {
  run ns --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"commands:"* ]]
}

@test "a symlink to bin/ns still finds its libraries" {
  ln -s "$NS_REPO_ROOT/bin/ns" "$BATS_TEST_TMPDIR/nslink"
  unset NS_HOME
  run "$BATS_TEST_TMPDIR/nslink" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"commands:"* ]]
}

#!/usr/bin/env bats
# ns-x8: guards that keep the bats suite fast. Real waits over 1s are replaced by
# waiting on a condition (marker file, polling at 0.1s), fake clocks or env overrides.
# Long sleeps (30s or more) are fine: they are placeholder processes the test kills.

@test "no test file waits on a real sleep of 2 to 29 seconds" {
  cd "$BATS_TEST_DIRNAME"
  run grep -nE '(^|[^[:alnum:]_.-])sleep +([2-9]|[12][0-9])(\.[0-9]+)?([^0-9.]|$)' -- *.bats helpers.bash
  if [ "$status" -eq 0 ]; then
    echo "real sleeps over 1s found (use a marker file, poll at 0.1s, or a fake clock):" >&2
    echo "$output" >&2
    return 1
  fi
}

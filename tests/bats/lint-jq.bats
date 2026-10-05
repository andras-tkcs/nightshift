#!/usr/bin/env bats
# ns-105: tests/lint guards against jq 1.8-only syntax and warns on jq version drift.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/bin" "$BATS_TEST_TMPDIR/fakebin"
}

fake_jq() {
  printf '#!/usr/bin/env bash\necho "jq-%s"\n' "$1" >"$BATS_TEST_TMPDIR/fakebin/jq"
  chmod +x "$BATS_TEST_TMPDIR/fakebin/jq"
}

@test "lint fails on unparenthesised reduce source followed by as" {
  cat >"$TREE/bin/bad.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq 'reduce .items | .[] as $x (0; . + $x)' <<<'{"items":[1]}'
SH
  NS_LINT_ROOT="$TREE" run "$REPO/tests/lint"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad.sh:3"* ]]
}

@test "lint fails on unparenthesised foreach source followed by as" {
  cat >"$TREE/bin/badfe.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq 'foreach .items | .[] as $x (0; . + $x)' <<<'{"items":[1]}'
SH
  NS_LINT_ROOT="$TREE" run "$REPO/tests/lint"
  [ "$status" -ne 0 ]
  [[ "$output" == *"badfe.sh:3"* ]]
}

@test "lint passes on a clean tree" {
  cat >"$TREE/bin/good.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq 'reduce (.items[]) as $x (0; . + $x)' <<<'{"items":[1]}'
SH
  NS_LINT_ROOT="$TREE" run "$REPO/tests/lint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lint: ok"* ]]
}

@test "lint warns when jq version differs from CI (1.7.1)" {
  cat >"$TREE/bin/good.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo ok
SH
  fake_jq 1.8.1
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" NS_LINT_ROOT="$TREE" run "$REPO/tests/lint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"jq 1.8.1"* && "$output" == *"CI"* && "$output" == *"1.7.1"* ]]
}

@test "lint does not warn when jq matches CI" {
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho ok\n' >"$TREE/bin/good.sh"
  fake_jq 1.7.1
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" NS_LINT_ROOT="$TREE" run "$REPO/tests/lint"
  [ "$status" -eq 0 ]
  [[ "$output" != *"differs"* ]]
}

@test "NS_LINT_STRICT_JQ=1 turns the version warning into a failure" {
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho ok\n' >"$TREE/bin/good.sh"
  fake_jq 1.8.1
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" NS_LINT_STRICT_JQ=1 NS_LINT_ROOT="$TREE" run "$REPO/tests/lint"
  [ "$status" -ne 0 ]
}

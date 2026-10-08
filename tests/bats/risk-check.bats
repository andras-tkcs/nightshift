#!/usr/bin/env bats
# ns-conductor risk-check <id> (ns-174, #169 part 1).
#
# Interface decided here: a subcommand, `ns-conductor risk-check <id>`. At Sync it matches the
# diff `origin/<git.base_branch>...<ledger feature_branch>` against the profile's risk_zones and
# platform_paths (platforms with verify: ci) and records in the run ledger:
#   - tags: `sec-compliance` and `risk:<zone>` for a risk-zone path, `platform:<p>` for a CI platform
#     path (added to the tags already there);
#   - risk_floor: T0 without a match, T1 with one;
#   - tier_recommended: only when risk_floor is above the ledger's tier (T1 for a T0 run).
# Its stdout names the recommendation ("tier_recommended T1") only in that case, so the conductor
# can put it in the ntfy line. It never writes tier or tier_source.

load helpers

fixture_vars() {
  FIX="$BATS_TEST_TMPDIR/fixture"
  WT="$NS_CODING_DIR/worktrees/nightshift-sandbox-sbx-12"
  LEDGER="$WT/.nightshift/runs/sbx-12/ledger.yaml"
}

# the slow part of the setup, run once per file (ns_cached_fixture)
fixture_build() {
  fixture_vars
  mkdir -p "$FIX/.claude" "$FIX/src/policy" "$FIX/.github/workflows"
  printf 'name: build\n' >"$FIX/.github/workflows/build.yml"
  cat >"$FIX/.claude/project-profile.yaml" <<'YAML'
project: nightshift-sandbox
prefix: sbx
commands:
  setup: "true"
  test: "true"
git: {}
stacks: [python]
platforms:
  linux: { verify: local }
  macos: { verify: ci, workflows: [build.yml] }
platform_paths:
  macos: ["**/*macos*"]
risk_zones:
  policy: { paths: ["src/policy/**"], require: [] }
YAML
  printf '# sandbox\n' >"$FIX/README.md"
  make_remote andras-tkcs/nightshift-sandbox "$FIX"
  "$NS_REPO_ROOT/bin/ns" project add andras-tkcs/nightshift-sandbox --prefix sbx >/dev/null
  "$NS_REPO_ROOT/bin/ns" new sbx-12 --tier T1 --yes >/dev/null
  local b f mk="$BATS_TEST_TMPDIR/mk"
  git clone -q "$(git -C "$WT" remote get-url origin)" "$mk"
  for b in policy:src/policy/rules.py macos:tools/setup_macos.sh plain:docs/notes.md; do
    f=${b#*:}
    git -C "$mk" checkout -q -b "feature/${b%%:*}" origin/main
    mkdir -p "$mk/$(dirname "$f")"
    printf 'x\n' >"$mk/$f"
    git -C "$mk" add "$f"
    git -C "$mk" -c user.name=t -c user.email=t@example.com commit -q -m "change $f"
    git -C "$mk" push -q origin "feature/${b%%:*}"
  done
  rm -rf "$mk"
}

setup() {
  ns_test_setup
  ns_cached_fixture fixture_build
  fixture_vars
}

# use_branch <name> <tier>: the run's feature branch and its owner-given tier
use_branch() {
  ns-ledger set "$LEDGER" ".feature_branch = \"feature/$1\""
  ns-ledger tier "$LEDGER" "$2" --source owner --hours 4
}

lget() { ns-ledger get "$LEDGER" "$1"; }

@test "risk-check: owner tier at the floor records tags and the floor but no tier_recommended" {
  use_branch policy T1
  run ns-conductor risk-check sbx-12
  assert_success
  [ "$(lget '.risk_floor')" = T1 ]
  [ "$(lget '.tags | index("sec-compliance") != null')" = true ]
  [ "$(lget '.tags | index("risk:policy") != null')" = true ]
  [ -z "$(lget '.tier_recommended // empty')" ]
  if grep -q tier_recommended <<<"$output"; then return 1; fi
  [ "$(lget '.tier')" = T1 ]
  [ "$(lget '.tier_source')" = owner ]
}

@test "risk-check: owner tier above the floor records no tier_recommended" {
  use_branch policy T2
  run ns-conductor risk-check sbx-12
  assert_success
  [ "$(lget '.risk_floor')" = T1 ]
  [ -z "$(lget '.tier_recommended // empty')" ]
}

@test "risk-check: a diff without a risk match has floor T0 and recommends nothing" {
  use_branch plain T0
  run ns-conductor risk-check sbx-12
  assert_success
  [ "$(lget '.risk_floor')" = T0 ]
  [ "$(lget '.tags | length')" = 0 ]
  [ -z "$(lget '.tier_recommended // empty')" ]
}

@test "risk-check: a floor above the owner tier records tier_recommended and names it" {
  use_branch policy T0
  run ns-conductor risk-check sbx-12
  assert_success
  [ "$(lget '.risk_floor')" = T1 ]
  [ "$(lget '.tier_recommended')" = T1 ]
  assert_output_contains "tier_recommended T1"
  # the owner's tier stands
  [ "$(lget '.tier')" = T0 ]
  [ "$(lget '.tier_source')" = owner ]
}

@test "risk-check: a CI platform path gives the platform tag and floor T1" {
  use_branch macos T0
  run ns-conductor risk-check sbx-12
  assert_success
  [ "$(lget '.tags | index("platform:macos") != null')" = true ]
  [ "$(lget '.risk_floor')" = T1 ]
  [ "$(lget '.tier_recommended')" = T1 ]
}

@test "risk-check: an unknown run exits 1" {
  run ns-conductor risk-check nosuch-1
  assert_failure 1
}

load helpers

setup() { ns_test_setup; P="$NS_REPO_ROOT/plugins/ns"; }

@test "the 11 agents of D15 exist" {
  local a
  for a in triage conductor researcher product-analyst architect planner test-architect implementer code-reviewer sec-compliance integrator; do
    [ -f "$P/agents/$a.md" ] || { echo "missing agent $a"; return 1; }
  done
}

@test "the 7 command skills and 14 method skills of D15 exist" {
  local s
  for s in run plan implement dod status resume review \
    triage-rubric run-ledger plan-manifest adr test-strategy review-checklist secure-code-review \
    compliance-mapping research-notes worktree-hygiene budget-guard handoff-report ci-dispatch review-desk; do
    [ -f "$P/skills/$s/SKILL.md" ] || { echo "missing skill $s"; return 1; }
  done
  [ -f "$P/skills/handoff-report/template.html" ]
}

@test "every executable named in hooks.json exists and is executable" {
  local c f n=0
  while IFS= read -r c; do
    f="${c//\"/}"
    f="${f//\$\{CLAUDE_PLUGIN_ROOT\}/$P}"
    [ -x "$f" ] || { echo "not executable: $f"; return 1; }
    n=$((n + 1))
  done < <(jq -r '.hooks[][].hooks[].command' "$P/hooks/hooks.json")
  [ "$n" -gt 0 ]
}

@test "every ns-conductor word in the plugin is a listed subcommand" {
  local w subs
  subs="$("$NS_REPO_ROOT/bin/ns-conductor" --help | awk '/^  [a-z]/ {print $1}')"
  while IFS= read -r w; do
    grep -qxF -- "$w" <<<"$subs" || { echo "unknown ns-conductor subcommand: $w"; return 1; }
  done < <(grep -rhoE 'ns-conductor [a-z][a-z-]*' --include='*.md' "$P" | awk '{print $2}' | sort -u)
}

@test "every ns word in the plugin names bin/lib/ns-<word>.sh" {
  local w
  while IFS= read -r w; do
    [ -f "$NS_REPO_ROOT/bin/lib/ns-$w.sh" ] || { echo "unknown ns subcommand: $w"; return 1; }
  done < <({ grep -rhoE '`ns [a-z][a-z-]*' --include='*.md' "$P" | sed 's/^`ns //'
             grep -rhoE '(^|[^-/a-zA-Z:`])ns [a-z][a-z-]* ' --include='*.md' "$P" | sed -E 's/^.*ns ([a-z-]+) $/\1/'; } | sort -u)
}

@test "every ns:<name> not preceded by a slash names an agent" {
  local w
  while IFS= read -r w; do
    [ -f "$P/agents/$w.md" ] || { echo "unknown agent: ns:$w"; return 1; }
  done < <(grep -rhoE '(^|[^/a-zA-Z0-9_-])ns:[a-z][a-z-]*' --include='*.md' "$P" | sed -E 's/.*ns://' | sort -u)
}

@test "every /ns:<name> names a skill directory" {
  local w
  while IFS= read -r w; do
    [ -d "$P/skills/$w" ] || { echo "unknown skill: /ns:$w"; return 1; }
  done < <(grep -rhoE '/ns:[a-z][a-z-]*' --include='*.md' "$P" | sed 's|/ns:||' | sort -u)
}

@test "every RUN file in an agent's Outputs appears in the run or implement skill" {
  local f rf
  for f in "$P"/agents/*.md; do
    while IFS= read -r rf; do
      rf="${rf%%\**}"
      rf="${rf%%<*}"
      grep -qF -- "$rf" "$P/skills/run/SKILL.md" "$P/skills/implement/SKILL.md" \
        || { echo "$(basename "$f"): $rf not named in run/implement skill"; return 1; }
    done < <(awk '/^## /{o=($0=="## Outputs")} o' "$f" | grep -oE 'RUN/[A-Za-z0-9_<>*.-]+' | sed -E 's/\.$//' | sort -u)
  done
}

@test "Nightshift's own profile checks ok" {
  export NS_AGENTS_DIR="$P/agents"
  cd "$NS_REPO_ROOT"
  run "$NS_REPO_ROOT/bin/ns" profile check .
  echo "$output"
  [[ "$output" == *"ok:"* ]]
}

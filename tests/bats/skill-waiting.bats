#!/usr/bin/env bats
# ns-174 (#169 part 1): the conductor waits for subagents through the Agent call or its task
# notification and for workers through `ns-conductor wait`; no skill text describes a fetch, sleep
# or file-poll loop, and the conductor leaves a worktree alone while an implementer works in it.

load helpers

FILES=(plugins/ns/skills/run/SKILL.md plugins/ns/skills/implement/SKILL.md plugins/ns/agents/implementer.md)

@test "run, implement and implementer describe no fetch, sleep or file-poll loop" {
  local f
  for f in "${FILES[@]}"; do
    [ -f "$NS_REPO_ROOT/$f" ]
    if grep -nE '(^|[^[:alnum:]])sleep +[0-9]' "$NS_REPO_ROOT/$f"; then return 1; fi
    if grep -nE '(while|until) .*(git fetch|sleep|\[ *-[fe] )' "$NS_REPO_ROOT/$f"; then return 1; fi
    if grep -niE 'in a loop|up to 60 times' "$NS_REPO_ROOT/$f"; then return 1; fi
  done
}

@test "run and implement tell the conductor to wait for the Agent return or the task notification" {
  local f
  for f in plugins/ns/skills/run/SKILL.md plugins/ns/skills/implement/SKILL.md; do
    grep -qiE 'task notification' "$NS_REPO_ROOT/$f"
    grep -qiE 'never (write|run|use).*(fetch|sleep|poll)' "$NS_REPO_ROOT/$f"
  done
  grep -qF 'ns-conductor wait' "$NS_REPO_ROOT/plugins/ns/skills/run/SKILL.md"
}

@test "run, implement and implementer keep the conductor out of a worktree in use" {
  local f
  for f in "${FILES[@]}"; do
    grep -qiE 'ns-conductor checks.*(only )?after the implementer (has )?returned' "$NS_REPO_ROOT/$f"
  done
}

@test "run skips triage when the owner gave the tier and runs risk-check at Sync" {
  grep -qF 'ns-conductor risk-check' "$NS_REPO_ROOT/plugins/ns/skills/run/SKILL.md"
  grep -qiE 'tier_source.*owner.*(not|never|skip).*triage|(not|never|skip).*triage.*owner' "$NS_REPO_ROOT/plugins/ns/skills/run/SKILL.md"
  if grep -qF 'also when the owner gave' "$NS_REPO_ROOT/plugins/ns/skills/run/SKILL.md"; then return 1; fi
}

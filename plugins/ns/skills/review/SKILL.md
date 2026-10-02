---
name: review
description: Walk the owner through gate 2 of a finished Nightshift run: handoff report, pull request and manual follow-ups.
argument-hint: "<run id>"
disable-model-invocation: true
---

# /ns:review

Gate 2 is the owner's review of the finished pull request. Steps:

1. Run `ns status <id>` and read the PR URL (`pr`) and the project.
2. Open the handoff report on the desk: `$NS_DESK_DIR/<repo>/runs/<id>/handoff.html` (also listed in `$NS_DESK_DIR/<repo>/index.md`). Summarise it: what changed, checks, board findings, open items.
3. Run `gh pr view <pr>` and report the title, the checks and any open items in the PR body.
4. List the `manual_after` items from the plan document (the `## Implementation manifest` block at the profile's `git.plan_doc`, in the run worktree), one per line, as steps only the owner can do after the merge.
5. Remind the owner that you do not merge: the owner merges the PR on GitHub, then does the manual items.

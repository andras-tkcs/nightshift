---
name: worktree-hygiene
description: How run and phase worktrees are named, created and cleaned up; load before creating, reusing or removing a worktree.
user-invocable: false
---

# Worktree hygiene

- Names come from the profile: its `worktrees` template and `git.*` branch templates. Never invent your own paths or branch names; `ns-conductor` creates them.
- The run worktree stays on `plan/<id>`. Code lives in `<id>--fix` (T0, T1) or `<id>--feature` (T2, T3); each phase worker has `<id>--<phase>`.
- One worktree per branch. Never check the same branch out twice and never switch a worktree to another branch.
- Never remove a worktree that holds unpushed commits or uncommitted work. Check first with `git -C <worktree> status --short` and `git -C <worktree> log --oneline @{u}..`. Push, or escalate if you cannot.
- `ns-conductor merge` removes a phase worktree after a successful merge. Leave every other cleanup to `ns gc`, which removes worktrees of finished runs.
- Do not delete branches by hand.

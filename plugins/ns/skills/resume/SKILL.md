---
name: resume
description: Restart a parked, stopped or crashed Nightshift run, or explain why it waits for the owner.
argument-hint: "<run id>"
disable-model-invocation: true
---

# /ns:resume

A run is in one of two kinds of pause.

- A gate: the run waits for the owner (state `waiting`, `gate` set to 1, 1.5 or 2). The owner reads and edits the desk documents, then runs `ns approve <id>`, which commits the desk versions, clears the gate and resumes the run.
- A parked run: state `parked` or `stopped`, or `running` without a tmux session after a crash. `ns resume <id>` rebuilds the worktree if needed, reconciles the phases against the feature branch (merged phases are never started again) and restarts the conductor.

Steps:

1. Run `ns status <id>` and read `state` and `gate`.
2. Gate set: do not resume. Tell the owner: `<id> waits at gate <g>: edit the desk documents, then ns approve <id>`.
3. State `done` or `failed`: report that there is nothing to resume.
4. Otherwise run `ns resume <id>` and report its output (`resumed <id>`, or `<id> is already running`).

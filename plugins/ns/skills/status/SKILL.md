---
name: status
description: Show the state of one Nightshift run, or list all runs.
argument-hint: "[run id]"
disable-model-invocation: true
---

# /ns:status

1. With a run id: run `ns status <id>` and summarise it in a few lines: tier and who set it, state, gate, step, budget used against the limit, branches and PR, each phase with its state, and the last events. Say what the run waits for, if anything.
2. Without an id: run `ns ls` and report each run in one line. If it prints `no runs`, say so.
3. Do not change anything; this skill only reads.

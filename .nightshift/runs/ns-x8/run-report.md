# Run report: ns-x8

- Project: nightshift
- Tier: T1
- State: done
- Pull request: https://github.com/andras-tkcs/nightshift/pull/165
- Times are UTC and come from the run ledger. Tokens, cost and check results come from the run's logs (`logs/ns-x8/` in the Nightshift config directory).

## Summary

| Measure | Value |
|---|---|
| Wall time | 5h 22m |
| Active time | 5h 19m |
| Waiting for you | 2m |
| Dead or stopped | 47s |
| Budget | 3.98 h of 5 h |
| Cost | $0.08 |
| Tokens | 49.1k (input 4, output 136, cache read 30.0k, cache write 19.0k) |
| Review rounds | 2 |
| Escalations | 2 |
| Checks | 1 PASS, 1 no data |

Escalations:

- 2026-10-07 15:32 (gate 1.5): budget used up: 2.04 h of 2 h
- 2026-10-07 15:35 (gate 1.5): budget used up: 2.05 h of 2 h

## Timeline

| Step | Start | Wall | Active | Waiting | Tokens | Cost |
|---|---|---|---|---|---|---|
| planning | 2026-10-07 12:12 | 3h 30m | 3h 26m | 2m | 11.34M | at least $0.08 |
| escalation (gate 1.5) | 2026-10-07 15:32 | 1m | 0s | 1m | 0 | $0.00 |
| escalation (gate 1.5) | 2026-10-07 15:35 | 1m | 0s | 1m | 0 | $0.00 |
| fix review round 2 | 2026-10-07 15:42 | 1h 38m | 1h 38m | 0s | 2.25M | no data |
| conductor work | 2026-10-07 17:20 | 14m | 14m | 0s | 459.0k | no data |

## Tokens and cost

By agent. A subagent's tokens and cost are part of the agent that started it.

| Agent | Log | Sessions | Turns | Input | Output | Cache read | Cache write | Cost |
|---|---|---|---|---|---|---|---|---|
| conductor | conductor.jsonl | 1 | 2 | 4 | 136 | 30.0k | 19.0k | $0.08 |

- conductor.jsonl: 2 sessions have no result event (cut off); their tokens and cost are not in the totals.

By model:

| Model | Input | Output | Cache read | Cache write | Cost |
|---|---|---|---|---|---|
| claude-sonnet-5-5 | 4 | 136 | 30.0k | 19.0k | $0.08 |
| Total | 4 | 136 | 30.0k | 19.0k | $0.08 |

Subagents:

| Subagent | Started by | Model | Runs | Time |
|---|---|---|---|---|
| ns:code-reviewer | conductor | claude-opus-5-5 | 2 | 2m |
| ns:implementer | conductor | claude-sonnet-5-5 | 3 | at least 8m |
| ns:integrator | conductor | claude-sonnet-5-5 | 2 | at least 1h 20m |
| ns:triage | conductor | claude-sonnet-5-5 | 1 | 18s |

## Checks

The last run of `ns-conductor checks` for each target.

| Target | Check | Result | Time | Start |
|---|---|---|---|---|
| feature | python lint | PASS | 24s | 2026-10-07 17:20 |
| feature | python test | no data | no data | no data |

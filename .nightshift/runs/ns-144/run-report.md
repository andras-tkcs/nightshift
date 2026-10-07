# Run report: ns-144

- Project: nightshift
- Tier: T2
- State: waiting
- Pull request: none
- Times are UTC and come from the run ledger. Tokens, cost and check results come from the run's logs (`logs/ns-144/` in the Nightshift config directory).

## Summary

| Measure | Value |
|---|---|
| Wall time | 52m |
| Active time | 51m |
| Waiting for you | 45s |
| Dead or stopped | 0s |
| Budget | 0.86 h of 8 h |
| Cost | $4.68 |
| Tokens | 4.68M (input 196, output 73.8k, cache read 4.10M, cache write 509.6k) |
| Review rounds | 0 |
| Escalations | 0 |
| Checks | no data |

## Timeline

| Step | Start | Wall | Active | Waiting | Tokens | Cost |
|---|---|---|---|---|---|---|
| planning | 2026-10-07 04:46 | 51m | 51m | 0s | 4.31M | $4.53 |
| gate 1 wait | 2026-10-07 05:38 | 45s | 0s | 45s | 369.5k | $0.15 |

## Tokens and cost

By agent. A subagent's tokens and cost are part of the agent that started it.

| Agent | Log | Sessions | Turns | Input | Output | Cache read | Cache write | Cost |
|---|---|---|---|---|---|---|---|---|
| conductor | conductor.jsonl | 1 | 23 | 196 | 73.8k | 4.10M | 509.6k | $4.68 |

By model:

| Model | Input | Output | Cache read | Cache write | Cost |
|---|---|---|---|---|---|
| claude-opus-5-5 | 144 | 66.8k | 3.23M | 444.8k | $4.21 |
| claude-sonnet-5-5 | 52 | 7.0k | 869.3k | 64.8k | $0.48 |
| Total | 196 | 73.8k | 4.10M | 509.6k | $4.68 |

Subagents:

| Subagent | Started by | Model | Runs | Time |
|---|---|---|---|---|
| ns:architect | conductor | claude-opus-5-5 | 1 | 1m |
| ns:planner | conductor | claude-opus-5-5 | 1 | 14m |
| ns:product-analyst | conductor | claude-opus-5-5 | 1 | 46s |
| ns:test-architect | conductor | claude-opus-5-5 | 1 | 33m |
| ns:triage | conductor | claude-sonnet-5-5 | 1 | 12s |

## Checks

No checks log in `logs/ns-144/`: no data.

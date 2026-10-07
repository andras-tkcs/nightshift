# Run report: ns-x9

- Project: nightshift
- Tier: T1
- State: running
- Pull request: none
- Times are UTC and come from the run ledger. Tokens, cost and check results come from the run's logs (`logs/ns-x9/` in the Nightshift config directory).

## Summary

| Measure | Value |
|---|---|
| Wall time | 4h 46m |
| Active time | 3h 46m |
| Waiting for you | 0s |
| Dead or stopped | 59m |
| Budget | 2.1 h of 2 h |
| Cost | $1.21 |
| Tokens | 2.54M (input 184, output 19.7k, cache read 2.37M, cache write 154.1k) |
| Review rounds | 1 |
| Escalations | 0 |
| Checks | 1 no data |

## Timeline

| Step | Start | Wall | Active | Waiting | Tokens | Cost |
|---|---|---|---|---|---|---|
| planning | 2026-10-07 13:54 | 1h 54m | 1h 54m | 0s | 1.39M | $0.78 |
| conductor work | 2026-10-07 15:49 | 1h 19m | 1h 19m | 0s | 1.15M | $0.43 |
| conductor work | 2026-10-07 18:08 | 32m | 32m | 0s | 478.0k | no data |

## Tokens and cost

By agent. A subagent's tokens and cost are part of the agent that started it.

| Agent | Log | Sessions | Turns | Input | Output | Cache read | Cache write | Cost |
|---|---|---|---|---|---|---|---|---|
| conductor | conductor.jsonl | 1 | 47 | 184 | 19.7k | 2.37M | 154.1k | $1.21 |

- conductor.jsonl: 1 session has no result event (cut off); its tokens and cost are not in the totals.

By model:

| Model | Input | Output | Cache read | Cache write | Cost |
|---|---|---|---|---|---|
| claude-opus-5-5 | 14 | 2.8k | 111.8k | 21.5k | $0.19 |
| claude-sonnet-5-5 | 170 | 17.0k | 2.25M | 132.6k | $1.03 |
| Total | 184 | 19.7k | 2.37M | 154.1k | $1.21 |

Subagents:

| Subagent | Started by | Model | Runs | Time |
|---|---|---|---|---|
| ns:code-reviewer | conductor | claude-opus-5-5 | 1 | 41s |
| ns:implementer | conductor | claude-sonnet-5-5 | 2 | 20m |
| ns:integrator | conductor | claude-sonnet-5-5 | 1 | no data |
| ns:integrator | conductor | unknown | 1 | no data |
| ns:triage | conductor | claude-sonnet-5-5 | 1 | 13s |

## Checks

The last run of `ns-conductor checks` for each target.

| Target | Check | Result | Time | Start |
|---|---|---|---|---|
| feature | python lint | no data | no data | no data |

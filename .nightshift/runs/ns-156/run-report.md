# Run report: ns-156

- Project: nightshift
- Tier: T1
- State: done
- Pull request: https://github.com/andras-tkcs/nightshift/pull/177
- Times are UTC and come from the run ledger. Tokens, cost and check results come from the run's logs (`logs/ns-156/` in the Nightshift config directory).

## Summary

| Measure | Value |
|---|---|
| Wall time | 25m |
| Active time | 25m |
| Waiting for you | 0s |
| Dead or stopped | 0s |
| Budget | 0.42 h of 2 h |
| Cost | no data |
| Tokens | 1.52M partial (input 110, output 953, cache read 1.37M, cache write 158.0k) |
| Review rounds | 1 |
| Escalations | 0 |
| Checks | 2 PASS |

## Timeline

| Step | Start | Wall | Active | Waiting | Tokens | Cost |
|---|---|---|---|---|---|---|
| planning | 2026-10-08 07:09 | 24m | 24m | 0s | 1.52M | no data |

## Tokens and cost

By agent. A subagent's tokens and cost are part of the agent that started it.

| Agent | Log | Sessions | Turns | Input | Output | Cache read | Cache write | Cost |
|---|---|---|---|---|---|---|---|---|
| conductor | conductor.jsonl | 0 | 0 | 110 | 953 | 1.37M | 158.0k | no data (partial) |

- conductor.jsonl: 1 session has no result event (cut off); its cost is not in the totals; the tokens are summed from the assistant messages (partial).

By model:

| Model | Input | Output | Cache read | Cache write | Cost |
|---|---|---|---|---|---|
| claude-opus-5-5 | 14 | 84 | 130.8k | 27.7k | no data |
| claude-sonnet-5-5 | 96 | 869 | 1.23M | 130.2k | no data |
| Total | 110 | 953 | 1.37M | 158.0k | no data |

Subagents:

| Subagent | Started by | Model | Runs | Time |
|---|---|---|---|---|
| ns:code-reviewer | conductor | claude-opus-5-5 | 1 | 41s |
| ns:implementer | conductor | claude-sonnet-5-5 | 2 | 2m |
| ns:integrator | conductor | unknown | 1 | 36s |
| ns:triage | conductor | claude-sonnet-5-5 | 1 | 11s |

## Checks

The last run of `ns-conductor checks` for each target.

| Target | Check | Result | Time | Start |
|---|---|---|---|---|
| feature | python lint | PASS | 20s | 2026-10-08 07:13 |
| feature | python test | PASS | 10m | 2026-10-08 07:13 |

### Checks breakdown

Every run of each check in the run's checks logs, with the total time of the runs that have times.

| Check | Runs | Total time |
|---|---|---|
| python lint | 1 | 20s |
| python test | 1 | 10m |

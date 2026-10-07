# DoD ns-x6 (fix/ns-x6 at cf26c0f)

| Check | Result | Detail |
|---|---|---|
| `tests/lint` | PASS | `ns-conductor checks ns-x6 fix`: PASS python lint |
| `bats --jobs "$(nproc)" tests/bats` | FAIL (1, pre-existing) | Not rerun at integrate: the machine load average was about 35 from other runs and two attempts hit the 10 minute limit. Result taken from the implementer's full run on this commit: one failure, bootstrap.bats 'step 1 with a failing apt-get', which also fails on origin/main (follow-up note 1 in notes.md). All other tests pass. |
| Conditional rows | n/a | profile has no `docs.dod` |
| Judgement rows | n/a | profile has no `docs.dod` |

Verdict: ready for a PR; the only failing row is the pre-existing bootstrap.bats failure that is unrelated to this diff.

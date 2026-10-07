# Budget exceeded

Run ns-x9 (T1) used 2.52 h of its 2 h wall-clock budget at step `integrate`. The deterministic budget check in `ns-conductor budget-check` stopped its workers and escalated the run here (R-BUD-1).

## Question

Give the run more time, or stop it? To continue, raise `budget_hours` below to the new limit in hours (above 2.52), then run `ns approve ns-x9`. To end the run, run `ns stop ns-x9` instead.

## Owner's answer

budget_hours: 2

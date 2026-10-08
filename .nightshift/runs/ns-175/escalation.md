# Budget exceeded

Run ns-175 (T1) used 2.2 h of its 2 h wall-clock budget at step `implement`. The deterministic budget check in `ns-conductor budget-check` stopped its workers and escalated the run here (R-BUD-1).

## Question

Give the run more time, or stop it? To continue, raise `budget_hours` below to the new limit in hours (above 2.2), then run `ns approve ns-175`. To end the run, run `ns stop ns-175` instead.

## Owner's answer

budget_hours: 2

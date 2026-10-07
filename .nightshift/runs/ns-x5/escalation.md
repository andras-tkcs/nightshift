# Budget exceeded

Run ns-x5 (T2) used 8.11 h of its 8 h wall-clock budget at step `board`. The deterministic budget check in `ns-conductor budget-check` stopped its workers and escalated the run here (R-BUD-1).

## Question

Give the run more time, or stop it? To continue, raise `budget_hours` below to the new limit in hours (above 8.11), then run `ns approve ns-x5`. To end the run, run `ns stop ns-x5` instead.

## Owner's answer

budget_hours: 8

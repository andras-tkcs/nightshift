# Budget exceeded

Run ns-x7 (T2) used 8.06 h of its 8 h wall-clock budget at step `phases`. The deterministic budget check in `ns-conductor budget-check` stopped its workers and escalated the run here (R-BUD-1).

## Question

Give the run more time, or stop it? To continue, raise `budget_hours` below to the new limit in hours (above 8.06), then run `ns approve ns-x7`. To end the run, run `ns stop ns-x7` instead.

## Owner's answer

budget_hours: 8

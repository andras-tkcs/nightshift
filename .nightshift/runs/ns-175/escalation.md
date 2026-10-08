# Escalation ns-175

Implementation is done and pushed on fix/ns-175 (e49a88e): `approve-after-nits` in review-round/merge, bats tests, docs, CHANGELOG. The agent could not run tests/lint (guard hook refused); the covering bats tests and docs-check passed.

`ns-conductor checks ns-175 feature` (full suite) was started in the foreground, moved to the background at 10 min and killed at the background time limit (20 min in total) with no result and no checks.rc marker. The code review has not run yet.

## Question
The full suite does not finish inside the tool time limit (10 min foreground, 10 min background). How should I proceed: run it outside the conductor session (for example `ns check`), or allow a longer limit?

## Owner's answer


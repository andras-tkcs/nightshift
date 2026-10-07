# Escalation: p3-retire cannot merge (known failure)

p1 and p2 are merged and pushed (p2 was merged on the earlier waiver; the first board run found them unpushed, I pushed `feature/x5` and ran p3-retire: docs, CHANGELOG, plan removal). p3 was approved in review (round 1, head 86efdfb). `ns-conductor merge ns-x5 p3-retire` exits 1 because the full checks fail on the known `bootstrap.bats` #32 (apt-get, no sudo on ns-main), which you accepted earlier. `ns-conductor` has no way to record a waiver, so every merge, and `ns-conductor finish`, will hit it.

## Question

Do you want to fix or skip `bootstrap.bats` #32 on main (then I re-run the merge), or should I merge `feature/x5--p3-retire` into `feature/x5` by hand (docs-only change) and continue to the review board and PR with #32 listed as a known failure?

## Owner's answer


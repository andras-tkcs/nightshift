# Escalation: p2-docs-retire merge blocked by the kill.bats timing case

## What is stuck
p2-docs-retire is reviewed and approved (head 1b04385, review round 1). `ns-conductor merge` runs the feature checks and they fail twice, each time on one case only: `kill.bats` "ns_kill_group gives up after about 2 s when the group does not go away (#58)", line 190 (`[ $(($(date +%s) - start)) -le 5 ]`). p2 changes docs only, so it cannot cause this; the case is a timing check that fails when ns-main is loaded by other runs (it also failed once earlier under p1).

Board status: p1 merged. The first board code review asked for the docs phase (now p2); acceptance board and a second board code review are still to run after p2 merges.

## What was tried
Merge twice (about 30 minutes apart); log at ~/.config/ns/logs/ns-144/feature.checks.log.

## Question
How shall I proceed with the kill.bats #58 timing flake: (a) you merge p2 yourself / tell me to merge it with the failing check accepted and I note the flake, or (b) fix the case (loosen the 5 s bound or isolate it) in a small extra phase first?

## Owner's answer

I already have a fix for this in a separate job. skip it for now and let the other job to cover it


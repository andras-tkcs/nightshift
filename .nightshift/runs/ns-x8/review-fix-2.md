# Review ns-x8 (T1 fix), round 2

Range: `git diff origin/main...origin/fix/ns-x8`, focus on changes since approved head 363a4fd (merge 317d553 of feature/144, commit a1c7c39).

## Findings

- non-blocking · tests/bats/bootstrap.bats:419-420 · the conflict resolution kept both comment lines ("...with the stubs linked last so they win:" and "...the stubs are linked last and win"), so the comment says the same thing twice · collapse to one line, e.g. "PATH of every tool but caddy via two batched ln calls; the stubs are linked last so they win".
- non-blocking · tests/bats/health.bats:365-369 · the poll now gives up after 50 tries (5 s) without saying why; if it gives up, the next assertion fails with no hint · optionally add a short comment that the cap only prevents a hang and the assertion below still catches a slow host.
- non-blocking · docs/development.md:18 · the new timing note (33.1 min with `--jobs 4` under load average 25-28) is accurate as a record but sits next to the 358 s figure with no "after this fix" number · put the post-fix timing from RUN/timing-after.md in the PR body as the plan requires; update the doc figure if the after-run on a quiet host differs.

## Summary

- Merge 317d553: the bootstrap.bats conflict was resolved in favour of the batched `find ... -exec ln -sf -t ... {} +` form from fix/ns-x8 and kept feature/144's comment about the tmux stub. Behaviour is the same as both sides: caddy is excluded from /usr/bin by `! -name caddy`, and the caddy stub in tests/fixtures/bootstrap/bin is removed by `rm -f .../caddy`, the same as the old per-tool `[ "$(basename "$s")" = caddy ] ||` filter. The PATH, `assert_failure 1` and both grep assertions are unchanged. The rest of feature/144 came in through a clean merge.
- drain-up.bats: instead of a fixed `sleep 0.5`, the background job now waits until `ns drain` has set `stop_requested` (ns-drain.sh:54), up to 10 s, before it parks the run. That removes the race where the run was parked before drain looked at it. `--timeout 30` leaves enough headroom. `assert_success` and the exact output assertion are unchanged.
- health.bats: the endless `until` loop is now capped at 50 x 0.1 s. Before, an empty `ps` result (the process had exited) would hang the test forever. Now it fails through the unchanged `assert_output_contains "health   silent 34m"`, so nothing is weakened.
- helpers.bash: the header comment now matches what the code does (later phases add helpers). The comment is the only change.
- No assertion was removed or weakened in these commits. No files from the forbidden zones (bin/ns-launch, bin/lib/config.sh, plugins/ns/hooks/**) and no `.nightshift/` files are on the branch. I found no text copied from untrusted sources. I did not run the checks because the caller did not ask for them.

REVIEW verdict=approve head=a1c7c395c7e5e4a6ae10e2824d1942309ca80bb7

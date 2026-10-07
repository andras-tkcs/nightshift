# Review ns-x4 fix, round 1

Range: `origin/main...origin/fix/ns-x4`, head 14cd2611725947da0eeb001186d3829d2cb7c985.

## Findings

- blocking · docs/security.md:87 · The list of allowed `ns` commands still names `health-check`, not `check`. The mini-plan lists docs/security among the docs to update, and the checklist treats a missing doc update as blocking. · Change `` `health-check` `` to `` `check` `` in that list. If you like, add "(and its deprecated alias `health-check`)". Leave line 25 as it is: "health-check URL" there is the healthchecks ping URL (`NS_HEALTHCHECK_URL`), not the command.
- non-blocking · tests/bats/health.bats:359,369 · The two new tests use a raw `[[ "$output" == *"ns check: "* ]]` where the rest of the file uses `assert_output_contains`. · Use `assert_output_contains "ns check: "` for consistency.

## Summary

The rename is mechanical and correct. `git mv` keeps history (92% similarity). The functions are now `ns_check_main` and `ns_check_help`, and the usage and summary text say `ns check`. In `bin/ns` the alias `[ "$cmd" != health-check ] || cmd=check` sits before the name and file check, the same way as `purge`->`rm`, so `ns health-check --help` also works. `ns help` lists files, so it now shows `check` and does not show the alias, which is fine for a deprecated alias.

The failing tests are in their own commit (78817c2), before the fix. Both would fail on main: `ns check` has no file there, and `health-check` prints `ns health-check:`, not `ns check:`. No existing test was weakened: only the command name changed in the existing tests.

The systemd ExecStart is updated, and the unit names stay as the plan says. The CHANGELOG mentions the deprecated alias. Comments in bin/ns-conductor, bin/ns-launch and bin/lib/ns-stop.sh are updated, and so are the schema description, the three skills and docs (usage, setup, conductor, operations). The one doc still to fix is docs/security.md.

There are no `.nightshift/` files, no secrets and no text copied from untrusted sources. I did not run the checks (the caller did not ask me to). I took the known bootstrap.bats apt-get failure as pre-existing, as the caller said.

REVIEW verdict=changes head=14cd2611725947da0eeb001186d3829d2cb7c985

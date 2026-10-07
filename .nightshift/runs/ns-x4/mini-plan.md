# Mini-plan ns-x4: rename `ns health-check` to `ns check`

Not a bug fix: a rename. Owner tier T1 (triage recommended T2; scope kept mechanical).

## Hypothesis / approach
`bin/ns` dispatches to `bin/lib/ns-<cmd>.sh` with functions `ns_<cmd>_main/_help`.
Rename the file and functions, keep `ns health-check` working as a deprecated alias.

## Failing test first
In tests/bats/health.bats (and run-new.bats lines ~374): add a test that `ns check`
runs the health check (summary line `ns check: ...`), and that `ns health-check` still works as an alias
(same behaviour). Run: it fails before the rename.

## Change
- git mv bin/lib/ns-health-check.sh bin/lib/ns-check.sh; rename ns_health_check_* to ns_check_*;
  usage and summary text say `ns check`.
- bin/ns: `[ "$cmd" != health-check ] || cmd=check` (like purge->rm).
- Update existing tests to `ns check`.
- templates/systemd/ns-health.service: ExecStart `ns check`. Unit names stay (ns-health.*).
- Comments/docs: bin/ns-conductor, bin/ns-launch, bin/lib/ns-stop.sh, schema/ledger.schema.json description,
  plugins/ns/skills (run, implement, budget-guard), docs (usage, setup, conductor, operations, security),
  CHANGELOG entry (mention deprecated alias). Leave docs/build-plan.md and spec history alone.
- tests/lint, bats, tests/docs-check must pass.

## Files
bin/ns, bin/lib/ns-check.sh, bin/ns-conductor, bin/ns-launch, bin/lib/ns-stop.sh, schema/ledger.schema.json,
templates/systemd/ns-health.service, plugins/ns/skills/{run,implement,budget-guard}/SKILL.md, docs/*.md,
CHANGELOG.md, tests/bats/health.bats, tests/bats/run-new.bats.

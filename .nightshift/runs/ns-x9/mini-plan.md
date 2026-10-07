# Mini-plan ns-x9: printf with format starting "--"

Cause: bash `printf '--json ...'` treats the format as an option: "printf: --: invalid option".
Found by grep: bin/lib/ns-ls.sh:12, bin/lib/ns-status.sh:14, bin/lib/ns-gc.sh:22 (usage/help text).

Failing test (tests/bats, e.g. cli.bats or new printf-dashes.bats):
- `ns ls --help`, `ns status --help`, `ns gc --help` (whatever each accepts) exit 0, stderr has no "invalid option", and stdout contains the `--json` / `--dry-run` line.
- Plus a lint-style test: grep over bin/ finds no `printf` whose format begins with `-` without a preceding `--`.

Fix: change those three to `printf -- '...'`. Also grep for other cases (variable formats, `printf "-..."`, echo of leading-dash strings) and fix them.

Files: bin/lib/ns-ls.sh, ns-status.sh, ns-gc.sh, tests/bats/*.bats. Run tests/lint and the bats suite.

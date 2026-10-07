# Review fix ns-x9, round 1

Range: `origin/main...origin/fix/ns-x9`, head 622b409b727bc48c01da1d9747202a03f36f27a3.

## Findings

- non-blocking · tests/bats/printf-dashes.bats:30 · The lint test's regex `printf +(['"])-` only catches literal quoted formats. Variable formats (`printf "$x"`) and unquoted `printf -x` slip through. I grepped bin/ at this head and found none, so nothing is broken today · Optionally widen the pattern later, or rely on shellcheck SC2059 for variable formats.

## Summary

- Correctness: the three help lines the mini-plan names (ns-ls.sh:12, ns-status.sh:14, ns-gc.sh:22) now use `printf -- '...'`. `bin/ns` sends `--help` to `ns_<cmd>_help`, so the tests exercise the changed code. A grep of bin/ found no other `printf` or `echo` format that starts with a dash.
- Tests: the failing test is in its own commit (122ff20), before the fix commit (622b409). It covers all three help commands (exit 0, no "invalid option" on stderr, the dash line on stdout) and adds the grep-based lint test, as the mini-plan asks. No existing test was changed.
- Simplicity and scope: only the files the mini-plan allows were touched. There are no stray files and no `.nightshift/` files.
- Docs: only the help text changed, so no docs needed updating.
- Untrusted text: none was copied into the change.
- I did not run any checks, because the caller did not ask for them.

REVIEW verdict=approve head=622b409b727bc48c01da1d9747202a03f36f27a3

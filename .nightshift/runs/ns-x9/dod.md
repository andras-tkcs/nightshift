# Definition of done: ns-x9

| Check | Result | Detail |
|---|---|---|
| `tests/lint` | PASS | via ns-conductor checks |
| `bats --jobs <nproc> tests/bats` | PASS | via ns-conductor checks (bootstrap.bats test 32 is known to fail on main in some environments, ledger note 1; it passed in this run) |
| docs.dod | n/a | profile sets no docs.dod |
| Conditional rows | n/a | none defined |
| Docs | ok | only help-text printf changed |

Verdict: ready to open the pull request.

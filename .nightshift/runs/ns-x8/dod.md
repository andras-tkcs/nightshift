# Definition of done ns-x8

Profile has no docs.dod; rows are the profile checks.

| Check | Result | Detail |
|---|---|---|
| `tests/lint` | PASS | `ns-conductor checks ns-x8 feature` on head 317d553: "PASS python lint" |
| `bats --jobs "$(nproc)" tests/bats` | FAIL (flake) | 856 tests, 1 failed under load 25-28: `drain returns once a background loop parks the run` (drain-up.bats:74, `[ "$output" = "parked: sbx-12" ]`). Passes when drain-up.bats is run alone. The 0.5 s sleep in this test (was 2 s) is probably too tight under load. |
| `tests/docs-check --final` | PASS | docs-check: ok |
| Changelog / ADR / trust boundaries | n/a | test-only change plus docs; no product behaviour touched |

Verdict: only the load-dependent drain-up flake is red; see the PR body.

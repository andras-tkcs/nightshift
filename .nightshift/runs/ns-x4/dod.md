# Definition of done: ns-x4

No `docs.dod` in the profile; checks are the profile's lint and test commands, run by `ns-conductor checks ns-x4 fix` after merging origin/main.

| Check | Result | Detail |
|---|---|---|
| `tests/lint` | PASS | exit 0 (the implementer had not run it; run now) |
| `bats --jobs "$(nproc)" tests/bats` | FAIL (non-blocking, environmental) | One failure: `not ok 32 step 1 with a failing apt-get does not report changed and exits non-zero` (tests/bats/bootstrap.bats line 304). It fails on the base branch too and is unrelated to the rename. All other tests pass. |
| `tests/docs-check --final` | PASS | docs-check: ok |
| CHANGELOG entry | ok | `[Unreleased]` / Changed; merge conflict with origin/main's Fixed entry resolved by keeping both |

Verdict: ready for a PR; the only failing row is the pre-existing bootstrap.bats apt-get test.

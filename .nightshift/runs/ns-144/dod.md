# DoD: ns-144 (feature/144 at df81e02, merged with origin/main)

No `docs.dod` in the profile; the rows are the profile checks.

| Check | Result | Detail |
|---|---|---|
| `tests/lint` | PASS | `ns-conductor checks ns-144 feature` exit 0 |
| `bats --jobs "$(nproc)" tests/bats` | PASS | 853 ok, 0 not ok (kill.bats #58 did not fail this time) |
| typecheck / audit | n/a | not set in the profile |
| Changelog entry | ok | CHANGELOG.md [Unreleased]: Security, Added (merge conflict with origin/main resolved by keeping both) |
| ADR | ok | docs/adr/0010-desk-content-policy.md, listed in docs/adr/README.md |
| Docs touched | ok | security, setup, operations, spec, architecture.html |
| Trust boundaries | ok | bootstrap never opens, writes or deletes files in Caddyfile.d |

Verdict: ready to open the pull request.

# Board acceptance: ns-144

Range: `git diff origin/main...origin/feature/144`, head e15bbe7f025a252d9f350c62df4771e53ef76b22 (merge of p2-docs-retire 1b04385; `git diff --quiet 1b04385 e15bbe7` shows the trees are identical). Checks ran in a detached worktree of that head at /tmp/ns144-board/wt.

AC-1 met: `bats tests/bats/bootstrap.bats` passes case "the HTML listeners send the CSP header and serve Markdown as text, per block (#5, #27)" (tests/bats/bootstrap.bats:286, helper csp_and_md_per_block at :266 checks the :8443 and :8080 blocks one at a time with awk). Template lines templates/caddy/Caddyfile.tmpl:15 and :33 carry the exact policy.
AC-2 met: same case greps `@md path *.md` and `Content-Type "text/plain; charset=utf-8"` per block; template :16-20 and :34-38 (`header @md { Content-Type ...; defer }`).
AC-3 met: `grep -v '^[[:space:]]*$' templates/caddy/Caddyfile.tmpl | tail -n1` prints `import /etc/caddy/Caddyfile.d/*.caddy`; also bats case "the Caddyfile template imports Caddyfile.d last (#26)" (:295) passes.
AC-4 met: bats case "step 1 apply creates Caddyfile.d and a rerun keeps a local snippet byte-identical (#26)" (:322) passes; it runs `NS_BS_STEPS=1 bootstrap_apply` three times, checks mode 755, sha256 and that `local.caddy` is the only entry. Code: bin/bootstrap.sh apply_1 `install -d -m 755 "$dir/Caddyfile.d"`.
AC-5 met: bats case "--check lists local Caddy snippets on the step 1 line and changes nothing (#26)" (:338) passes; asserts `[1/11] ...: ok (local: local.caddy)` and equal snapshots.
AC-6 met: `bats tests/bats/bootstrap.bats` exit 0, 49 of 49 ok, including "--check on an empty tree reports each step and changes nothing" (:82) and "--check on a prepared tree prints eleven ok lines and exits 0" (:97). The new cases use only NS_BS_ROOT and the stubs; none runs as root.
AC-7 met: docs/adr/0010-desk-content-policy.md exists, Status Accepted, covers what the desk serves, why both the header and `ns publish` exist (Decision 3), and forbids scripts and outside loads (Decision 1); docs/adr/README.md:16 lists 0010; docs/security.md:36 names the CSP header and links ADR 0010; docs/setup.md step 1 (:68) names the CSP header, `*.md` as `text/plain` and `/etc/caddy/Caddyfile.d/*.caddy` that bootstrap never touches. `tests/docs-check` exit 0 (`docs-check: ok`).
AC-8 met: ~/.config/ns/logs/ns-144/p2-docs-retire.checks.log on 1b04385 (same tree as the head): `tests/lint` PASS exit 0, `bats --jobs "$(nproc)" tests/bats` PASS exit 0, 840 of 840 ok; checks.rc 0. Here: `shellcheck -x bin/bootstrap.sh` exit 0 (the only changed bash file; tests/lint itself was blocked by the ns guard hook in this session). My own full-suite run was stopped by the 30 min tool limit at 381 of 840 cases with 0 failures under load from another run. The kill.bats #58 timing case that failed the feature merge checks is owner-accepted and handled in a separate job (escalation.md), so it does not block here.

## Non-goals

- held: the :443 and :8444 blocks have no CSP and no @md (template diff; also asserted in csp_and_md_per_block).
- held: `git diff origin/main...origin/feature/144 -- bin/lib/desk.sh` is empty.
- held: bootstrap only creates Caddyfile.d and lists `*.caddy` names with `find -printf '%f'`; it never opens, writes or deletes files there; no snippet is shipped.
- held: the bin/bootstrap.sh diff touches only check_1 and apply_1.

## Findings

- blocking: none.
- non-blocking (carried from board-code.md, still open): tests/bats/bootstrap.bats:287, 296, 323, 339, 352, 366, 381, the bodies of the seven new `@test` cases are not indented.

REVIEW verdict=approve

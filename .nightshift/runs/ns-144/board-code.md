# Board code review: ns-144

Range: `git diff origin/main...origin/feature/144`, head 747ce0742ea2e602e227216f21b86d8d84afa586.
Inputs: docs/ns-144-plan.md (on the branch), CLAUDE.md, docs/spec.md, review-checklist skill. No worker log or reasoning was read.

## Findings

- blocking · docs/ (whole branch) · Phase p2-docs-retire is not merged into feature/144. The diff touches only bin/bootstrap.sh, templates/caddy/Caddyfile.tmpl, tests/bats/bootstrap.bats and the plan. None of the docs the change affects are updated: no docs/adr/0010-desk-content-policy.md, no row in docs/adr/README.md, nothing in docs/security.md, docs/setup.md step 1 (its manual block still lacks `install -d -m 755 /etc/caddy/Caddyfile.d`), docs/operations.md "Updates", docs/spec.md step 1 or docs/architecture.html (which still tells the owner to add the CSP by hand with nano), and no CHANGELOG [Unreleased] entries for #5, #27, #26. This breaks CLAUDE.md "every phase updates the docs it affects (spec §15)" and the plan's final_checks. · Run p2-docs-retire as the plan's D5/D6 describe, merge it with `--no-ff` and a `Plan-Phase: p2-docs-retire` trailer, then ask for a new board review.
- blocking · docs/ns-144-plan.md:1 · The plan file is still on the feature branch. The final_checks require "docs/ns-144-plan.md is deleted" before the PR. · Delete it with `git rm` as the last change of p2.
- non-blocking · tests/bats/bootstrap.bats:90 · The empty-tree assertion `grep -E '^\[1/11\].*create /etc/caddy/Caddyfile\.d'` was added in the implementation commit 43d03d1, not in the test-first commit 6a21abd, so it never failed first. The plan (D4) asked for it, and the behaviour is simple. · In future runs, put this assertion in the acceptance-test commit too.
- non-blocking · tests/bats/bootstrap.bats:286,295,322,339,353,367,382 · When the `ns_xfail` prefixes were removed, the helper calls inside the seven new `@test` bodies were left at column 0. Every other case in the file indents its body. · Indent them by two spaces.
- non-blocking · bin/bootstrap.sh:173-176 · In apply_1 the "Caddyfile.d is not a directory" guard runs after caddy may already have been installed and TS_PERMIT_CERT_UID written, so a needs-you leaves step 1 half applied. This is harmless, because both steps are idempotent, and it is the placement D3 specifies. · You could move the guard to the top of apply_1 in a follow-up.
- non-blocking · tests/bats/bootstrap.bats:418-420 · The failing-apt-get case now also links tests/fixtures/bin/* (the tmux stub) into its PATH. This is in scope (only an allowed file is touched), no assertion was weakened, and the order keeps the bootstrap stubs winning. · None needed. Mention it in the PR body as a test robustness fix.

## Summary

Phase p1 matches the plan exactly. The D1 template lines sit in the :8443 and :8080 blocks only, and the import is the last line. The D2 check_1 lists snippet names through `find -printf '%f'` and `clean`, and never opens the files. D3 adds the apply_1 guard and creates the directory with `install -d -m 755`. The seven D4 cases were committed as strict expected failures before the fix, and the fix commit removed only the xfail wrappers. No existing assertion was weakened. Nothing in the diff was copied from untrusted text (R-SEC-3), there are no secrets, and no `.nightshift/` files are on the branch.

The branch is not ready for the PR. Phase p2 (ADR 0010, the security, setup, operations, spec and architecture docs, the CHANGELOG and deleting the plan) is missing. Those are a missing doc update and an unmet final check, both blocking.

REVIEW verdict=changes head=747ce0742ea2e602e227216f21b86d8d84afa586
